#!/usr/bin/env python3
"""Package the original 26 plus three 1112 RQ16 styles and 12 1D LUTs.

The boot path copies this complete, 16-byte-aligned image from SPI Flash to DDR.
Model slots keep their existing 12,800-byte descriptor payload and 0xff pad;
packed LUT bytes follow the model slots in R,G,B order.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re

SLOT_BYTES = 16_384
PAYLOAD_BYTES = 12_800
SLOT_PAD = 0xFF
FLASH_BASE = 0x0040_0000
DDR_BASE = 0x01C0_0000
DDR_FINAL_C = 0x0200_0000
TABLE_BYTES = 768
CATALOG_SLOT_BYTES = 16
EXPECTED_MODEL_CONTRACT = {
    "table_width": 40,
    "table_depth": 2560,
    "weight_items": 1989,
    "parameter_items": 520,
    "used_items": 2509,
    "slot_items": 39,
    "parameter_keep": 20,
    "parameter_stream_slots": 2,
    "parameter_bits": 786,
    "stream_protocol": "single_srl40_v2",
}
EXPECTED_MODEL_ARCH = "v2e_factorizedshuffle / model_v2de.FactorizedShuffle"
EXPECTED_MODEL_SHA = "ceb076655fb778349600dfa0f44a341445cc8124d4012517e0587d26499886d6"
EXPECTED_RESIDUAL_SCALE = 6.0 / 127.0
EXPECTED_RESIDUAL_DOMAINS = ("enc", "body0", "body1", "body2", "body3", "dec")
PRE_SHIFT_MAX = 2
PRE_SHIFTED_ABS_MAX = (1 << 18) - 1
ACCUMULATOR_ABS_MAX = (1 << 23) - 1
M18_MIN, M18_MAX = 1 << 16, 1 << 17
POST_SHIFT_MIN, POST_SHIFT_MAX = 20, 28
MODEL_LABEL_OVERRIDES = {"pointillism": "POINTILL", "copper_relief": "COPPER",
                         "nobel_e": "NOBEL", "fst_mosaic": "MOSAIC"}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xFFFF
    return crc


def slug_from_folder(name: str) -> str:
    slug = name.rsplit("_", 1)[-1].lower()
    if not re.fullmatch(r"[a-z0-9]+", slug):
        raise ValueError(f"non-ASCII slug in folder name: {name}")
    return slug


def lut_slug_from_folder(name: str) -> str:
    slug = name.rsplit("-", 1)[-1].lower()
    if not re.fullmatch(r"[a-z0-9]+", slug):
        raise ValueError(f"non-ASCII LUT slug in folder name: {name}")
    return slug


def display_label(slug: str, limit: int) -> str:
    label = MODEL_LABEL_OVERRIDES.get(slug, slug.upper())
    if len(label) > limit:
        raise ValueError(f"UI label {label!r} exceeds {limit} characters")
    return label


def model_source_record(folder: Path, slot: int, *, source_slug: str | None = None) -> tuple[dict, bytes]:
    descriptor = json.loads((folder / "descriptor_package/manifest.json").read_text(encoding="utf-8"))
    ptq = json.loads((folder / "ptq/metadata.json").read_text(encoding="utf-8"))
    narrow = json.loads((folder / "rq16/rq16_narrow_manifest.json").read_text(encoding="utf-8"))
    payload = (folder / "descriptor_package/weight_table40.bin").read_bytes()
    slot_data = (folder / "weight_table40_slot16k.bin").read_bytes()
    slug = source_slug if source_slug is not None else slug_from_folder(folder.name)
    if not re.fullmatch(r"[a-z0-9_]+", slug):
        raise ValueError(f"invalid model slug: {slug!r}")
    source_name = ptq.get("source_checkpoint", "").replace("\\", "/").rsplit("/", 1)[-1]
    source_checkpoint = folder.parent.parent / source_name
    source_checkpoint_sha = sha(source_checkpoint.read_bytes()) if source_checkpoint.is_file() else None

    for field, expected in EXPECTED_MODEL_CONTRACT.items():
        if descriptor.get(field) != expected:
            raise ValueError(f"{folder.name}: descriptor {field}={descriptor.get(field)!r}, expected {expected!r}")
    ddr_image = descriptor.get("ddr_image", {})
    if (len(payload) != PAYLOAD_BYTES or ddr_image.get("bytes") != PAYLOAD_BYTES or
            ddr_image.get("item_bytes") != 5 or ddr_image.get("byte_order") != "little" or
            ddr_image.get("item_order") != "ascending table address"):
        raise ValueError(f"{folder.name}: descriptor DDR byte layout mismatch")
    if sha(payload) != ddr_image.get("sha256"):
        raise ValueError(f"{folder.name}: descriptor payload hash mismatch")
    if len(slot_data) != SLOT_BYTES or slot_data[:PAYLOAD_BYTES] != payload:
        raise ValueError(f"{folder.name}: 16KiB slot payload mismatch")
    if slot_data[PAYLOAD_BYTES:] != bytes([SLOT_PAD]) * (SLOT_BYTES - PAYLOAD_BYTES):
        raise ValueError(f"{folder.name}: slot padding is not 0xff")
    if (ptq.get("source_model") != EXPECTED_MODEL_ARCH or
            ptq.get("source_model_sha256") != EXPECTED_MODEL_SHA or
            ptq.get("quantized_conv_layers") != 17 or
            ptq.get("quantized_weight_count") != 8812):
        raise ValueError(f"{folder.name}: model architecture or quantized tensor count mismatch")
    if source_checkpoint_sha != ptq.get("source_checkpoint_sha256") or not source_checkpoint.is_file():
        raise ValueError(f"{folder.name}: source checkpoint is missing or differs from deployment metadata")
    if ("signed INT8 symmetric" not in ptq.get("activation_format", "") or
            "zero_point=0" not in ptq.get("activation_format", "") or
            "signed INT8 symmetric per output channel" not in ptq.get("weight_format", "") or
            "zero_point=0" not in ptq.get("weight_format", "")):
        raise ValueError(f"{folder.name}: expected symmetric signed INT8 quantization")
    scales = ptq.get("activation_scales", {})
    if not scales or any(not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0
                         for value in scales.values()):
        raise ValueError(f"{folder.name}: invalid activation scale values")
    domains = narrow.get("residual_domains", {})
    if any(not math.isclose(float(domains.get(key, float("nan"))), EXPECTED_RESIDUAL_SCALE,
                            rel_tol=0.0, abs_tol=1e-12) for key in EXPECTED_RESIDUAL_DOMAINS):
        raise ValueError(f"{folder.name}: residual activation domains differ from the fixed hardware contract")
    rq_layers = narrow.get("layers", {})
    if not isinstance(rq_layers, dict) or len(rq_layers) != 17:
        raise ValueError(f"{folder.name}: expected 17 RQ16 layer contracts")
    pre_shifts, m18_values, post_shifts, acc_bounds, pre_bounds, bias_bounds = [], [], [], [], [], []
    for layer_name, layer in rq_layers.items():
        pre_shift = layer.get("pre_shift")
        multipliers = layer.get("m18", [])
        channels = layer.get("post_shift", [])
        if not isinstance(pre_shift, int) or not 0 <= pre_shift <= PRE_SHIFT_MAX:
            raise ValueError(f"{folder.name}/{layer_name}: pre_shift outside RTL contract 0..2")
        if not multipliers or len(multipliers) != len(channels):
            raise ValueError(f"{folder.name}/{layer_name}: missing or mismatched M18/post_shift channels")
        if any(not isinstance(value, int) or not M18_MIN <= value < M18_MAX for value in multipliers):
            raise ValueError(f"{folder.name}/{layer_name}: M18 outside normalized 17-bit window")
        if any(not isinstance(value, int) or
               (value != 0 and not POST_SHIFT_MIN <= value <= POST_SHIFT_MAX) for value in channels):
            raise ValueError(f"{folder.name}/{layer_name}: post_shift outside RTL window {{0}} U 20..28")
        acc_bound = layer.get("theoretical_accumulator_bound")
        pre_bound = layer.get("theoretical_pre_shift_bound")
        bias_bound = layer.get("max_abs_bias_code")
        if (not isinstance(acc_bound, int) or not 0 <= acc_bound <= ACCUMULATOR_ABS_MAX or
                not isinstance(pre_bound, int) or not 0 <= pre_bound <= PRE_SHIFTED_ABS_MAX or
                not isinstance(bias_bound, int) or not 0 <= bias_bound <= ACCUMULATOR_ABS_MAX):
            raise ValueError(f"{folder.name}/{layer_name}: accumulator, pre-shift, or bias bound exceeds RTL width")
        pre_shifts.append(pre_shift); m18_values.extend(multipliers); post_shifts.extend(channels)
        acc_bounds.append(acc_bound); pre_bounds.append(pre_bound); bias_bounds.append(bias_bound)
    label = display_label(slug, 10)
    record = {
        "slot": slot,
        "folder": folder.name,
        "slug": slug,
        "display_name": label,
        "source_checkpoint": source_name,
        "source_checkpoint_sha256": source_checkpoint_sha,
        "descriptor_format": descriptor.get("format"),
        "payload_bytes": len(payload),
        "slot_bytes": len(slot_data),
        "payload_sha256": sha(payload),
        "slot_sha256": sha(slot_data),
        "valid_items": descriptor["used_items"],
        "zero_items": descriptor["table_depth"] - descriptor["used_items"],
        "weight_count": ptq["quantized_weight_count"],
        "activation_scale_min": min(float(v) for v in scales.values()),
        "activation_scale_max": max(float(v) for v in scales.values()),
        "rq16_contract_ranges": {
            "layer_count": len(rq_layers),
            "pre_shift_min": min(pre_shifts), "pre_shift_max": max(pre_shifts),
            "m18_min": min(m18_values), "m18_max": max(m18_values),
            "post_shift_min_nonzero": min(value for value in post_shifts if value),
            "post_shift_max": max(post_shifts),
            "theoretical_accumulator_bound_max": max(acc_bounds),
            "theoretical_pre_shift_bound_max": max(pre_bounds),
            "max_abs_bias_code": max(bias_bounds),
        },
        "residual_scale": EXPECTED_RESIDUAL_SCALE,
    }
    return record, slot_data


def lut_source_record(folder: Path, slot: int) -> tuple[dict, bytes]:
    meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
    lines = (folder / "table.mem").read_text(encoding="ascii").splitlines()
    if len(lines) != TABLE_BYTES or any(not re.fullmatch(r"[0-9a-fA-F]{2}", line.strip()) for line in lines):
        raise ValueError(f"{folder.name}: expected exactly 768 two-digit hexadecimal values")
    values = bytes(int(line.strip(), 16) for line in lines)
    if any(value & 0xC0 for value in values):
        raise ValueError(f"{folder.name}: LUT value exceeds the 6-bit hardware domain")
    if meta.get("id") != f"{slot + 1:02d}" or not meta.get("name_en") or not meta.get("name_zh"):
        raise ValueError(f"{folder.name}: LUT id/name metadata mismatch")
    slug = lut_slug_from_folder(folder.name)
    if meta["name_en"].lower() != slug:
        raise ValueError(f"{folder.name}: folder slug disagrees with meta.json")
    label = display_label(slug, 16)
    channels = [values[i * 256:(i + 1) * 256] for i in range(3)]
    record = {
        "slot": slot,
        "folder": folder.name,
        "slug": slug,
        "display_name": label,
        "name_zh": meta["name_zh"],
        "kind": meta.get("kind"),
        "recommended_mode": meta.get("mode"),
        "payload_bytes": len(values),
        "payload_sha256": sha(values),
        "value_min": min(values),
        "value_max": max(values),
        "channel_order": ["R", "G", "B"],
        "values_per_channel": 256,
        "hardware_address": "{phase[1:0],index[7:0]} with phase R,G,B",
        "channel_monotone": [all(channel[i] <= channel[i + 1] for i in range(255)) for channel in channels],
    }
    return record, values


def load_inputs(style_root: Path, lut_root: Path, extra_style_root: Path | None = None) -> tuple[list[dict], list[dict], bytes, bytes]:
    model_folders = sorted((p for p in style_root.iterdir() if p.is_dir() and int(p.name.split("_", 1)[0]) <= 26), key=lambda p: int(p.name.split("_", 1)[0]))
    lut_folders = sorted((p for p in lut_root.iterdir() if p.is_dir()), key=lambda p: int(p.name.split("-", 1)[0]))
    if len(model_folders) != 26 or len(lut_folders) != 12:
        raise ValueError(f"expected 26 deployed models and 12 LUTs, got {len(model_folders)} and {len(lut_folders)}")
    models, model_slots = [], []
    for index, folder in enumerate(model_folders):
        record, slot = model_source_record(folder, index)
        record["ddr_offset"] = index * SLOT_BYTES
        models.append(record)
        model_slots.append(slot)
    if extra_style_root is not None:
        extra = json.loads((extra_style_root / "additional_catalog.json").read_text(encoding="utf-8"))
        expected = ["copper_relief", "nobel_e", "fst_mosaic"]
        if extra.get("style_order") != expected or extra.get("slot_count") != 3:
            raise ValueError("additional style order/count mismatch")
        extra_bundle = (extra_style_root / "additional_bundle.bin").read_bytes()
        if len(extra_bundle) != 3 * SLOT_BYTES or sha(extra_bundle) != extra.get("bundle_sha256"):
            raise ValueError("additional bundle hash/length mismatch")
        if f"{crc16_ccitt_false(extra_bundle):04x}" != extra.get("bundle_crc16_ccitt_false"):
            raise ValueError("additional bundle CRC mismatch")
        for index, slug in enumerate(expected):
            folder = extra_style_root / f"{index + 27:02d}_{slug}"
            record, slot = model_source_record(folder, len(models), source_slug=slug)
            source = extra["slots"][index]
            if (source.get("slug") != slug or source.get("ui_label") != record["display_name"] or
                    source.get("slot_sha256") != sha(slot) or
                    extra_bundle[index*SLOT_BYTES:(index+1)*SLOT_BYTES] != slot):
                raise ValueError(f"{slug}: source catalog or combined slot differs")
            record["ddr_offset"] = len(models) * SLOT_BYTES
            record["source_group"] = "additional"
            models.append(record)
            model_slots.append(slot)
    luts, lut_payloads = [], []
    for index, folder in enumerate(lut_folders):
        record, payload = lut_source_record(folder, index)
        record["ddr_offset"] = len(models) * SLOT_BYTES + index * TABLE_BYTES
        luts.append(record)
        lut_payloads.append(payload)
    return models, luts, b"".join(model_slots), b"".join(lut_payloads)


def build_manifest(models: list[dict], luts: list[dict], model_slots: bytes,
                   lut_payload: bytes, bundle: bytes) -> dict:
    model_count, lut_count = len(models), len(luts)
    model_bytes = len(model_slots)
    catalog_model_bytes = model_count * CATALOG_SLOT_BYTES
    catalog_table_base = catalog_model_bytes
    # UI table slot zero is generated by the firmware's existing IDENTITY
    # preset path; it consumes no bytes in the external Flash/DDR LUT bundle.
    catalog_table_count = 1 + lut_count
    catalog_bytes = catalog_model_bytes + catalog_table_count * CATALOG_SLOT_BYTES
    return {
        "format": f"v2e_rq16_narrow_{model_count}_model_bundle_plus_{lut_count}_lut_v1",
        "architecture": EXPECTED_MODEL_ARCH,
        "model_slot_bytes": SLOT_BYTES,
        "model_payload_bytes": PAYLOAD_BYTES,
        "model_padding_bytes": SLOT_BYTES - PAYLOAD_BYTES,
        "model_padding_value": "0xff",
        "models": models,
        "lut_format": "1d_rgb_6bit_768_bytes_v1",
        "lut_payload_bytes_each": TABLE_BYTES,
        "lut_payload_bytes_total": len(lut_payload),
        "lut_order": luts,
        "bundle_layout": {
            "model_slots_offset": 0,
            "model_slots_bytes": model_bytes,
            "lut_payload_offset": model_bytes,
            "lut_payload_bytes": len(lut_payload),
            "total_bytes": len(bundle),
            "byte_order": "low DDR address at low byte; model descriptor items little-endian",
            "flash_base": f"0x{FLASH_BASE:08x}",
            "flash_end_exclusive": f"0x{FLASH_BASE + len(bundle):08x}",
            "ddr_base": f"0x{DDR_BASE:08x}",
            "ddr_end_exclusive": f"0x{DDR_BASE + len(bundle):08x}",
            "result_c_base": f"0x{DDR_FINAL_C:08x}",
            "ddr_gap_before_result_c_bytes": DDR_FINAL_C - (DDR_BASE + len(bundle)),
        },
        "model_hardware_contract": {
            **EXPECTED_MODEL_CONTRACT,
            "quantized_conv_layers": 17,
            "quantized_weight_count": 8812,
            "activation_format": "signed INT8 symmetric, zero_point=0",
            "weight_format": "signed INT8 symmetric per output channel, q[-127,127], zero_point=0",
            "residual_domains": {key: EXPECTED_RESIDUAL_SCALE for key in EXPECTED_RESIDUAL_DOMAINS},
        },
        "catalog": {
            "model_slots": model_count,
            "table_slots": catalog_table_count,
            "builtin_identity_slot": 0,
            "external_lut_assets": lut_count,
            "slot_bytes": CATALOG_SLOT_BYTES,
            "model_base": 0,
            "table_base": catalog_table_base,
            "total_bytes": catalog_bytes,
            "address_width_bits": math.ceil(math.log2(catalog_bytes)),
            "csr_index_data_bits": "cfg_wdata[9:0], low byte in [7:0], high bits in [9:8]",
            "count_csr": "0x078: actual model count[4:0], table count[11:8]; table count includes built-in IDENTITY",
        },
        "bundle_bytes": len(bundle),
        "bundle_sha256": sha(bundle),
        "bundle_crc16_ccitt_false": f"{crc16_ccitt_false(bundle):04x}",
        "lut_payload_sha256": sha(lut_payload),
    }


def emit_sv_package(path: Path, manifest: dict) -> None:
    model_count = len(manifest["models"])
    lut_count = len(manifest["lut_order"])
    catalog = manifest["catalog"]
    layout = manifest["bundle_layout"]
    text = f'''// Generated by tools/generate_model_assets.py from assets/catalog_manifest.json.
package demo_model_asset_pkg;
    localparam integer MODEL_COUNT={model_count};
    localparam integer MODEL_PAYLOAD_BYTES={PAYLOAD_BYTES};
    localparam integer MODEL_SLOT_BYTES={SLOT_BYTES};
    localparam integer MODEL_SLOT_BUNDLE_BYTES=MODEL_COUNT*MODEL_SLOT_BYTES;
    localparam integer MODEL_LUT_COUNT={lut_count};
    localparam integer MODEL_LUT_BYTES={TABLE_BYTES};
    localparam integer MODEL_LUT_BUNDLE_BYTES=MODEL_LUT_COUNT*MODEL_LUT_BYTES;
    localparam integer MODEL_BUNDLE_BYTES=MODEL_SLOT_BUNDLE_BYTES+MODEL_LUT_BUNDLE_BYTES;
    localparam integer MODEL_CATALOG_MODEL_SLOTS={catalog['model_slots']};
    localparam integer MODEL_CATALOG_TABLE_SLOTS={catalog['table_slots']};
    localparam integer MODEL_CATALOG_SLOT_BYTES={CATALOG_SLOT_BYTES};
    localparam integer MODEL_CATALOG_TABLE_BASE={catalog['table_base']};
    localparam integer MODEL_CATALOG_BYTES={catalog['total_bytes']};
    localparam integer MODEL_CATALOG_ADDR_WIDTH={catalog['address_width_bits']};
    localparam integer MODEL_CATALOG_MODEL_BASE={catalog['model_base']};
    localparam logic [23:0] MODEL_FLASH_BUNDLE_ADDRESS=24'h{FLASH_BASE:06x};
    localparam logic [31:0] MODEL_DDR_BASE=32'h{DDR_BASE:08x};
    localparam logic [31:0] MODEL_LUT_DDR_BASE=32'h{DDR_BASE + model_count * SLOT_BYTES:08x};
    localparam logic [15:0] MODEL_BUNDLE_CRC16=16'h{int(manifest['bundle_crc16_ccitt_false'], 16):04x};
endpackage
'''
    path.write_text(text, encoding="ascii", newline="\n")


def emit_c_header(path: Path, manifest: dict) -> None:
    models = manifest["models"]
    luts = manifest["lut_order"]
    rows = []
    for model in models:
        rows.append(
            f'    {{"{model["display_name"]}", STYLE_MODEL_DDR_BASE+UINT32_C(0x{model["ddr_offset"]:06x}), '
            'SP_MODEL_BYTES, MODEL_FORMAT_W8A8, 1u}'
        )
    lut_rows = ['    {"IDENTITY", 0, TABLE_SOURCE_BUILTIN, STYLE_TABLE_PRESET_A, 1u}']
    for lut in luts:
        offset = lut["ddr_offset"] - len(models) * SLOT_BYTES
        lut_rows.append(
            f'    {{"{lut["display_name"]}", STYLE_MODEL_DDR_LUT_BASE+UINT32_C(0x{offset:04x}), '
            'TABLE_SOURCE_DDR, 0u, 1u}'
        )
    cat = manifest["catalog"]
    rows_text = ", \\\n".join(rows)
    lut_rows_text = ", \\\n".join(lut_rows)
    text = f'''#ifndef STYLE_MODEL_ASSETS_GENERATED_H
#define STYLE_MODEL_ASSETS_GENERATED_H
#include <stdint.h>
/* Generated from the final style_weights and lut_library assets. */
#define STYLE_MODEL_ASSET_COUNT {len(models)}u
#define STYLE_MODEL_SLOT_BYTES UINT32_C(0x{SLOT_BYTES:04x})
#define STYLE_MODEL_FLASH_BUNDLE_BYTES UINT32_C(0x{manifest['bundle_bytes']:06x})
#define STYLE_MODEL_BUNDLE_CRC16 UINT16_C(0x{int(manifest['bundle_crc16_ccitt_false'], 16):04x})
#define STYLE_MODEL_FLASH_BASE UINT32_C(0x{FLASH_BASE:08x})
#define STYLE_MODEL_DDR_BASE UINT32_C(0x{DDR_BASE:08x})
#define STYLE_MODEL_DDR_LUT_BASE UINT32_C(0x{DDR_BASE + len(models) * SLOT_BYTES:08x})
#define STYLE_LUT_ASSET_COUNT {len(luts)}u
#define STYLE_LUT_TABLE_BYTES UINT32_C(0x{TABLE_BYTES:04x})
#define STYLE_UI_CATALOG_MODEL_BASE {cat['model_base']}u
#define STYLE_UI_CATALOG_MODEL_SLOTS {cat['model_slots']}u
#define STYLE_UI_CATALOG_TABLE_BASE {cat['table_base']}u
#define STYLE_UI_CATALOG_TABLE_SLOTS {cat['table_slots']}u
#define STYLE_UI_CATALOG_SLOT_BYTES {CATALOG_SLOT_BYTES}u
#define STYLE_UI_CATALOG_TOTAL_BYTES {cat['total_bytes']}u
#define STYLE_UI_CATALOG_ADDR_WIDTH {cat['address_width_bits']}u
#define STYLE_UI_METADATA_MODEL_INDEX_LOW_SHIFT 5u
#define STYLE_UI_METADATA_MODEL_INDEX_MID_SHIFT 8u
#define STYLE_UI_METADATA_MODEL_INDEX_BIT3 27u
#define STYLE_UI_METADATA_MODEL_INDEX_BIT4 31u
#define STYLE_UI_METADATA_TABLE_INDEX_LOW_SHIFT 11u
#define STYLE_UI_METADATA_TABLE_INDEX_BIT3 28u
#define STYLE_UI_COUNT_CSR_OFFSET 0x78u
#define STYLE_UI_COUNT_MODEL_SHIFT 0u
#define STYLE_UI_COUNT_TABLE_SHIFT 8u
#define STYLE_UI_COUNT_MODEL_MASK UINT32_C(0x1f)
#define STYLE_UI_COUNT_TABLE_MASK UINT32_C(0x0f)
#define STYLE_MODEL_ASSET_ROWS \\
{rows_text}
#define STYLE_TABLE_ASSET_ROWS \\
{lut_rows_text}
#endif
'''
    path.write_text(text, encoding="ascii", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    project = Path(__file__).resolve().parents[1]
    repo_root = project.parents[1]
    parser.add_argument("--style-root", type=Path, default=repo_root / "assets/styles/deploy")
    parser.add_argument("--lut-root", type=Path, default=repo_root / "assets/luts/lut")
    parser.add_argument("--extra-style-root", type=Path, default=repo_root / "assets/styles/deploy")
    parser.add_argument("--manifest", type=Path, default=project / "assets/catalog_manifest.json")
    parser.add_argument("--bundle", type=Path, default=project / "assets/model_bundle_29x16k_lut12.bin")
    parser.add_argument("--lut-payload", type=Path, default=project / "assets/lut_tables_12x768.bin")
    parser.add_argument("--project", type=Path, default=project)
    parser.add_argument("--software", type=Path, default=project / "software")
    args = parser.parse_args()

    models, luts, model_slots, lut_payload = load_inputs(args.style_root, args.lut_root, args.extra_style_root)
    if len(models) > 31 or 1 + len(luts) > 15:
        raise ValueError("model/table counts exceed the existing UI CSR fields")
    bundle = model_slots + lut_payload
    if len(bundle) % 16:
        raise ValueError("complete boot image must be 16-byte aligned")
    if DDR_BASE + len(bundle) > DDR_FINAL_C:
        raise ValueError("combined model/LUT image overlaps result C")
    manifest = build_manifest(models, luts, model_slots, lut_payload, bundle)
    if manifest["catalog"]["address_width_bits"] > 10:
        raise ValueError("catalog exceeds existing 10-bit UI address field")
    manifest["bundle_file"] = args.bundle.name
    args.bundle.parent.mkdir(parents=True, exist_ok=True)
    args.lut_payload.write_bytes(lut_payload)
    args.bundle.write_bytes(bundle)
    args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    emit_sv_package(args.project / "rtl/demo_model_asset_pkg.sv", manifest)
    emit_c_header(args.software / "style_model_assets_generated.h", manifest)
    print(f"PASS models={len(models)} slots={len(model_slots)} bytes; luts={len(luts)} payload={len(lut_payload)} bytes")
    print(f"PASS bundle={len(bundle)} bytes crc16={manifest['bundle_crc16_ccitt_false']} sha256={manifest['bundle_sha256']}")
    print(f"PASS catalog={manifest['catalog']['total_bytes']} bytes ({manifest['catalog']['address_width_bits']} address bits)")


if __name__ == "__main__":
    main()
