"""Arithmetic architecture report; optional forward/backward/folding on CUDA only.

Run from repository root:
  python gesture/tools/profile_model.py --out gesture/reports/g4net_v1.json
  python gesture/tools/profile_model.py --cuda-check --device cuda:0 --out ...
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

GESTURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GESTURE))
from src.spec import DEFAULT_CONFIG, load_config


def profile(spec):
    cin = spec['input']['channels']
    h, w = spec['input']['height'], spec['input']['width']
    rf = jump = 1
    rows, stages = [], []

    def add_conv(name, cout, kernel, stride, groups):
        nonlocal cin, h, w, rf, jump
        ih, iw, ic = h, w, cin
        h = (h + 2 * (kernel // 2) - kernel) // stride + 1
        w = (w + 2 * (kernel // 2) - kernel) // stride + 1
        weights = cout * (cin // groups) * kernel * kernel
        rf += (kernel - 1) * jump
        jump *= stride
        rows.append(dict(name=name, op='conv', kernel=kernel, stride=stride,
                         padding=kernel // 2, groups=groups,
                         input_chw=[ic, ih, iw], output_chw=[cout, h, w],
                         macs=h * w * weights, weights=weights,
                         bn_channels=cout, input_int8_bytes=ic * ih * iw,
                         output_int8_bytes=cout * h * w,
                         receptive_field=rf, output_stride=jump))
        cin = cout

    def add_tap(name, cout, kernel, position):
        """A branch off the stream: it reads a block's output and returns nothing
        to the sequence, so it must not advance `cin`, `h`, `w` or `jump`."""
        weights = cout * cin * kernel * kernel
        rows.append(dict(name=name, op='conv', kernel=kernel, stride=1,
                         padding=kernel // 2, groups=1,
                         input_chw=[cin, h, w], output_chw=[cout, h, w],
                         macs=h * w * weights, weights=weights,
                         bn_channels=cout, input_int8_bytes=cin * h * w,
                         output_int8_bytes=cout * h * w,
                         receptive_field=rf, output_stride=jump, tap=True,
                         tap_block=position['tap']))

    position = spec.get('position_head')
    for block in spec['blocks']:
        begin = len(rows)
        if block['type'] == 'dsconv':
            add_conv(block['name'] + '.dw', cin, 3, block['stride'], cin)
            add_conv(block['name'] + '.pw', block['out_channels'], 1, 1, 1)
        else:
            add_conv(block['name'], block['out_channels'], block['kernel'],
                     block['stride'], 1)
        stages.append(dict(name=block['name'], output_chw=[cin, h, w],
                           macs=sum(r['macs'] for r in rows[begin:]),
                           weights=sum(r['weights'] for r in rows[begin:]),
                           receptive_field=rf, output_stride=jump))
        # The head is computed as soon as its source block exists, so its row
        # sits where it runs: the memory model below then sees the real
        # lifetimes instead of a tap tacked onto the end of the stream.
        if position is not None and position['tap'] == block['name']:
            add_tap('position', position['out_channels'], position['kernel'],
                    position)

    conv_channels = sum(r['bn_channels'] for r in rows)
    conv_weights = sum(r['weights'] for r in rows)
    classifier = spec.get('classifier')
    fc_weights = cin * classifier['out_features'] if classifier else 0
    total_weights = conv_weights + fc_weights
    head_extra = 4 if classifier else 0   # FC bias / its per-class requant channels
    # Only the streaming rows alternate between two buffers. The tap is a branch:
    # its source is already the current activation, and its own output is small,
    # so folding it into the alternation would shift every parity after it and
    # report an arena figure that no schedule has to build.
    stream_rows = [r for r in rows if not r.get('tap')]
    tap_rows = [r for r in rows if r.get('tap')]
    activation_sizes = [stream_rows[0]['input_int8_bytes']] + [
        r['output_int8_bytes'] for r in stream_rows]
    arenas = [max(activation_sizes[0::2]), max(activation_sizes[1::2])]
    total_macs = sum(r['macs'] for r in rows) + fc_weights
    materialized_io = sum(r['input_int8_bytes'] + r['output_int8_bytes']
                          for r in stream_rows)
    materialized_io += sum(r['input_int8_bytes'] + r['output_int8_bytes']
                           for r in tap_rows)
    if classifier:
        materialized_io += cin * h * w + cin + cin + 8  # GAP INT8, FC INT16
    else:
        # Position-only: no reduce at all, the heatmap is the output.
        materialized_io += 0
    position_report = None
    if position is not None:
        tap = tap_rows[0]
        position_report = dict(
            tap_block=position['tap'], output_stride=position['output_stride'],
            kernel=position['kernel'], convolution=tap['name'],
            input_chw=tap['input_chw'], output_chw=tap['output_chw'],
            heatmap_cells=tap['output_chw'][1] * tap['output_chw'][2],
            macs=tap['macs'], weights=tap['weights'],
            activation=position['activation'], deployment=position['deployment'],
            target=position['target'], target_sigma_cells=position['target_sigma_cells'],
            loss=position['loss'],
            int8_output_bytes=tap['output_int8_bytes'],
            source_map_int8_bytes=tap['input_int8_bytes'],
            extra_arena_int8_bytes=tap['output_int8_bytes'],
            receptive_field=tap['receptive_field'],
            note=('The source map is the activation the stream has just produced, '
                  'so the tap adds its own output bytes to residency, not a second '
                  'copy of the source. It runs as one more layer in the schedule; '
                  'the sigmoid sits at export and is not folded here.'),
        )
    return dict(
        model_id=spec['model_id'], classes=spec['classes'],
        input_chw=[spec['input']['channels'], spec['input']['height'], spec['input']['width']],
        output_shape=[1, classifier['out_features']] if classifier else None,
        classifier=bool(classifier),
        position_head=position_report, stages=stages,
        convolutions=rows,
        total_macs_per_frame=total_macs, conv_count=len(rows),
        conv_weight_elements=conv_weights, fc_weight_elements=fc_weights,
        training_parameters=total_weights + 2 * conv_channels + head_extra,
        bn_running_buffer_elements=2 * conv_channels + len(rows),
        folded_fp32_parameters=total_weights + conv_channels + head_extra,
        int8_weight_bytes=total_weights,
        folded_bias_int32_bytes=4 * (conv_channels + head_extra),
        per_channel_rq_multiplier_shift_int32_bytes=8 * (conv_channels + head_extra),
        activation_int8_peak_tensor_bytes=max(activation_sizes),
        activation_int8_peak_adjacent_pair_bytes=max(a + b for a, b in zip(activation_sizes, activation_sizes[1:])),
        activation_int8_alternating_arena_bytes=arenas,
        activation_int8_two_arena_total_bytes=sum(arenas),
        materialized_layer_io_bytes_per_frame=materialized_io,
        gap=dict(input_chw=[cin, h, w], spatial_elements=h * w,
                 additions=cin * (h * w - 1), output_channels=cin)
        if classifier else None,
        throughput_budget=[dict(fps=fps, macs_per_second=total_macs * fps,
                                required_efficiency_8dsp_100mhz_one_mac_per_cycle=total_macs * fps / 800_000_000)
                           for fps in (15, 30)],
        notes=[
            'Analytical counts, not measured accuracy, FPGA resource use or latency.',
            'MAC excludes BN, activation, GAP additions, resize and DMA.',
            'INT8 memory is a logical payload estimate; excludes alignment, port replication, line buffers, DMA and accumulators.',
            'Materialized IO assumes every primitive output is stored and each input read once; GAP is INT8 and FC output INT16. Excludes weights, refetches and bus overhead. The position tap is counted as one extra read of its source and one extra stored map.',
            '8 DSP @100 MHz with one INT8 MAC per DSP cycle is an unvalidated capacity assumption.',
        ])


def model_outputs(output, report):
    """(logits, heatmap), whichever of the two this model produces.

    A classifier-only model returns a bare logit tensor, a position-only model a
    bare heatmap, and a model with both returns a dict. Returning `None` for the
    absent one keeps every check below written once.
    """
    if isinstance(output, dict):
        return output['logits'], output['heatmap']
    if report['classifier']:
        return output, None
    return None, output


def cuda_check(spec, report, device_name):
    import numpy as np
    from PIL import Image
    import torch
    from torch import nn
    from src.model import ConvBNAct, G4Net
    from src.preprocess import preprocess_image

    device = torch.device(device_name)
    if device.type != 'cuda' or device.index is None:
        raise ValueError('Specify an explicit device such as cuda:0.')
    if not torch.cuda.is_available() or device.index >= torch.cuda.device_count():
        raise RuntimeError('Requested CUDA device unavailable; CPU fallback is forbidden.')
    # Image processing is on the host; all model execution below is on CUDA.
    height, width = spec['input']['height'], spec['input']['width']
    # A source already at the target aspect is a pure resize: no padding, and the
    # colour probes survive normalisation.
    pattern, _ = preprocess_image(Image.new('RGB', (width, height), (0, 128, 255)), spec)
    np.testing.assert_array_equal(pattern[:, 0, 0], [-1, 0, 127 / 128])
    assert pattern.dtype == np.float32 and pattern.flags.c_contiguous
    # A portrait source is the letterbox case: the padded columns must be exactly
    # the zero point of the normalisation, and the content must fill the height.
    portrait, geometry = preprocess_image(Image.new('RGB', (99, 301), (255, 255, 255)), spec)
    resized_w, resized_h = geometry['resized_wh']
    left = geometry['pad_left_top'][0]
    assert resized_h == height and geometry['pad_left_top'][1] == 0, geometry
    assert np.all(portrait[:, :, :left] == 0), 'left pillow is not the zero point'
    assert np.all(portrait[:, :, left + resized_w:] == 0), 'right pillow is not the zero point'
    assert np.all(portrait[:, :, left:left + resized_w] == 127 / 128), 'content is not intact'

    torch.cuda.set_device(device)
    torch.manual_seed(20261015)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    model = G4Net(spec).to(device).train()
    batch = torch.rand(2, *report['input_chw'], device=device) * (255 / 128) - 1
    labels = torch.tensor([0, 1], device=device)
    observed = []
    hooks = []
    for name, layer in model.named_modules():
        if isinstance(layer, nn.Conv2d):
            def observe(layer, inputs, output, name=name):
                observed.append((name, list(output.shape[1:]), layer.weight.numel()))
            hooks.append(layer.register_forward_hook(observe))
    logits, heatmap = model_outputs(model(batch), report)
    for hook in hooks:
        hook.remove()
    if report['classifier']:
        assert logits.shape == (2, 4) and logits.device == device
    assert len(observed) == report['conv_count']
    for (_, shape, weights), row in zip(observed, report['convolutions']):
        assert shape == row['output_chw'] and weights == row['weights'], row['name']
    loss = torch.zeros((), device=device)
    if report['classifier']:
        loss = loss + nn.functional.cross_entropy(logits, labels)
    if report['position_head'] is not None:
        from src.position import centre_loss
        expected = report['position_head']['output_chw']
        assert heatmap is not None and list(heatmap.shape) == [2, *expected], heatmap.shape
        # An all-background target: the point is that gradients reach the head,
        # not that random weights predict anything.
        loss = loss + centre_loss(heatmap, torch.zeros_like(heatmap))
    assert sum(p.numel() for p in model.parameters()) == report['training_parameters']
    loss.backward()
    assert torch.isfinite(loss).item()
    assert all(p.grad is not None and torch.isfinite(p.grad).all().item() for p in model.parameters())
    model.eval()
    deployed = model.to_deploy()
    assert not any(isinstance(m, nn.BatchNorm2d) for m in deployed.modules())
    assert sum(p.numel() for p in deployed.parameters()) == report['folded_fp32_parameters']
    reference_layers, folded_layers = {}, {}
    for network, values in ((model, reference_layers), (deployed, folded_layers)):
        for name, layer in network.named_modules():
            if isinstance(layer, ConvBNAct):
                def capture(layer, inputs, output, name=name, values=values):
                    values[name] = output.detach()
                hooks.append(layer.register_forward_hook(capture))
    with torch.no_grad():
        reference = model(batch)
        folded = deployed(batch)
        reference_logits, reference_heatmap = model_outputs(reference, report)
        folded_logits, folded_heatmap = model_outputs(folded, report)
        if report['classifier']:
            torch.testing.assert_close(folded_logits, reference_logits,
                                       rtol=1e-4, atol=1e-5)
        if report['position_head'] is not None:
            torch.testing.assert_close(folded_heatmap, reference_heatmap,
                                       rtol=1e-4, atol=1e-5)
        for name in reference_layers:
            torch.testing.assert_close(folded_layers[name], reference_layers[name],
                                       rtol=1e-4, atol=1e-5)
        max_error = None
        if report['classifier']:
            max_error = (folded_logits - reference_logits).abs().max().item()
        heatmap_error = None
        if report['position_head'] is not None:
            heatmap_error = (folded_heatmap - reference_heatmap).abs().max().item()
        layer_max_error = max((folded_layers[name] - value).abs().max().item()
                              for name, value in reference_layers.items())
        for hook in hooks:
            hook.remove()
        # Check dark, neutral and bright endpoints without a CPU model call.
        boundary = torch.stack([torch.full(report['input_chw'], value, device=device)
                                for value in (-1.0, 0.0, 127 / 128)])
        boundary_logits, boundary_heatmap = model_outputs(deployed(boundary), report)
        if boundary_logits is not None:
            assert torch.isfinite(boundary_logits).all().item()
        if boundary_heatmap is not None:
            assert torch.isfinite(boundary_heatmap).all().item()
    return dict(device=str(device), gpu=torch.cuda.get_device_name(device),
                torch_version=torch.__version__, synthetic_batch_size=2,
                output_shape=None if logits is None else list(logits.shape),
                heatmap_shape=None if heatmap is None else list(heatmap.shape),
                forward_backward_finite=True,
                analytical_shapes_and_parameters_match=True,
                bn_fold_max_abs_error=max_error,
                bn_fold_max_heatmap_abs_error=heatmap_error,
                bn_fold_max_layer_abs_error=layer_max_error,
                rgb_normalization_and_asymmetric_letterbox_checked=True,
                boundary_inputs_finite=True, trained=False,
                note='Random weights and synthetic inputs only; no accuracy or INT8 parity claim.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--cuda-check', action='store_true')
    parser.add_argument('--device', default='cuda:0')
    args = parser.parse_args()
    spec = load_config(args.config)
    report = profile(spec)
    report['config_sha256'] = hashlib.sha256(args.config.read_bytes()).hexdigest()
    report['source_sha256'] = {
        name: hashlib.sha256((GESTURE / name).read_bytes()).hexdigest()
        for name in ('src/model.py', 'src/spec.py', 'src/preprocess.py', 'tools/profile_model.py')
    }
    if args.cuda_check:
        report['cuda_check'] = cuda_check(spec, report, args.device)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"{report['model_id']}: {report['total_macs_per_frame']:,} MAC/frame; "
          f"{report['training_parameters']:,} training parameters; "
          f"{report['int8_weight_bytes']:,} INT8 weight bytes")
    print(f"INT8 arenas: {report['activation_int8_alternating_arena_bytes']}; "
          f"last local receptive field: {report['stages'][-1]['receptive_field']}")
    if report['position_head'] is not None:
        head = report['position_head']
        print(f"position head: tap {head['tap_block']} at stride "
              f"{head['output_stride']} -> {head['output_chw']} "
              f"({head['heatmap_cells']} cells); {head['macs']:,} MAC; "
              f"{head['activation']} at export")
    for row in report['stages']:
        print(f"{row['name']:5s} {str(row['output_chw']):16s} "
              f"MAC={row['macs']:>9,d} weights={row['weights']:>6,d} RF={row['receptive_field']}")
    if 'cuda_check' in report:
        print(json.dumps(report['cuda_check'], ensure_ascii=False))


if __name__ == '__main__':
    main()
