"""Pure, bounded command validation, recipe knowledge and existing UART v1 serialization."""
import copy
import json
import re
import struct
import binascii

# identity 为协议初始值（"空表"语义），与 12 张定稿表并列。
LUT_TABLES = {"identity": {"cn": "原始", "kind": "identity", "desc": "不加载调色表",
                           "swatch": [(32, 32, 32), (80, 80, 80), (128, 128, 128), (176, 176, 176), (224, 224, 224)]},
              "warm":        {"cn": "暖色",     "kind": "grade",    "desc": "整体暖调胶片感",
                         "swatch": [(0, 8, 16), (65, 69, 60), (130, 125, 113), (195, 178, 154), (255, 255, 251)]},
    "aged":     {"cn": "泛黄",     "kind": "grade",    "desc": "泛黄旧照片氛围",
                         "swatch": [(8, 12, 28), (81, 77, 60), (138, 134, 105), (186, 174, 138), (243, 255, 219)]},
    "verdant":         {"cn": "泛绿",     "kind": "grade",    "desc": "青绿清新自然感",
                         "swatch": [(0, 8, 20), (60, 60, 48), (109, 109, 81), (162, 150, 101), (239, 239, 190)]},
    "memory":    {"cn": "记忆",     "kind": "grade_bw", "desc": "低饱和银盐黑白",
                         "swatch": [(16, 28, 32), (69, 77, 69), (101, 113, 105), (170, 158, 138), (231, 227, 215)]},
    "cine": {"cn": "青橙",     "kind": "grade",    "desc": "青橙分离的电影调色",
                         "swatch": [(0, 8, 12), (60, 73, 60), (101, 117, 105), (186, 170, 146), (255, 255, 235)]},
    "neon":    {"cn": "酸性霓虹", "kind": "gradient", "desc": "黑→紫→品红→青→黄绿，霓虹感强烈",
                         "swatch": [(12, 0, 36), (178, 0, 125), (170, 60, 146), (12, 203, 203), (239, 255, 154)]},
    "cyan":    {"cn": "青版",     "kind": "gradient", "desc": "蓝白印相工艺感",
                         "swatch": [(8, 12, 32), (36, 73, 121), (69, 113, 162), (117, 166, 203), (235, 243, 255)]},
    "forest":       {"cn": "森绿",     "kind": "gradient", "desc": "墨绿→米白双色调",
                         "swatch": [(8, 24, 16), (48, 77, 56), (65, 101, 73), (113, 142, 113), (243, 235, 203)]},
    "thermal":     {"cn": "红外伪彩", "kind": "gradient", "desc": "黑→深红→橙→白的热感伪彩",
                         "swatch": [(0, 0, 8), (97, 8, 28), (162, 28, 20), (219, 85, 28), (255, 251, 227)]},
    "sunset":       {"cn": "日落",     "kind": "gradient", "desc": "紫黑→红→橙→金的晚霞映射",
                         "swatch": [(24, 8, 44), (125, 32, 69), (178, 60, 60), (231, 101, 48), (255, 239, 154)]},
    "duotone":  {"cn": "青橙影调", "kind": "gradient", "desc": "teal→orange 双色影调",
                         "swatch": [(8, 40, 48), (44, 81, 89), (60, 101, 109), (125, 117, 97), (255, 154, 65)]},
    "invert":         {"cn": "负片",     "kind": "curve",    "desc": "全通道反相底片",
                         "swatch": [(255, 255, 255), (170, 170, 170), (85, 85, 85), (0, 0, 0), (0, 0, 0)]},
}
RECIPES = [
    {"id": "neon", "cn": "赛博霓虹", "desc": "酸性霓虹表 + 灰度配色模式：亮度被映射为紫→品红→青→黄绿的霓虹色带",
     "changes": {"curve": "neon", "color": "gray", "ai_strength": 100, "effect": "direct", "view": "processed"}},
    {"id": "cyanotype", "cn": "青版印相", "desc": "青版表 + 灰度配色：蓝白工艺印相",
     "changes": {"curve": "cyan", "color": "gray", "ai_strength": 100, "view": "processed"}},
    {"id": "sunset", "cn": "落日熔金", "desc": "日落表 + 灰度配色：紫红→橙金晚霞",
     "changes": {"curve": "sunset", "color": "gray", "ai_strength": 100, "view": "processed"}},
    {"id": "infrared", "cn": "红外热感", "desc": "红外伪彩表 + 灰度配色：热成像式伪彩",
     "changes": {"curve": "thermal", "color": "gray", "ai_strength": 100, "view": "processed"}},
    {"id": "forest", "cn": "森绿单色", "desc": "森绿表 + 灰度配色：墨绿→米白双色调",
     "changes": {"curve": "forest", "color": "gray", "ai_strength": 100, "view": "processed"}},
    {"id": "teal_orange_cine", "cn": "青橙影调", "desc": "青橙影调表 + 灰度配色：阴影偏青、高光偏橙的影调",
     "changes": {"curve": "duotone", "color": "gray", "ai_strength": 100, "view": "processed"}},
    {"id": "warm_film", "cn": "暖调胶片", "desc": "暖色表 + RGB 曲线模式：整体暖调的电影胶片感",
     "changes": {"curve": "warm", "color": "curve", "ai_strength": 100, "view": "processed"}},
    {"id": "aged_paper", "cn": "泛黄旧忆", "desc": "泛黄表 + RGB 曲线模式：老照片黄调",
     "changes": {"curve": "aged", "color": "curve", "ai_strength": 100, "view": "processed"}},
    {"id": "mono_memory", "cn": "银盐记忆", "desc": "记忆表 + RGB 曲线模式：低饱和黑白银盐",
     "changes": {"curve": "memory", "color": "curve", "ai_strength": 100, "view": "processed"}},
    {"id": "negative_film", "cn": "底片反相", "desc": "负片表 + RGB 曲线模式：全通道反相",
     "changes": {"curve": "invert", "color": "curve", "ai_strength": 100, "view": "processed"}},
]
RECIPE_IDS = {r["id"] for r in RECIPES}

# 26 个实际上板风格：assets/styles/deploy/catalog_manifest.json（index/name_en/name_cn）
STYLES = {
    "vangogh": "梵高星空", "popcomic": "波普漫画", "candy": "糖果", "pointillism": "点彩印象",
    "blueprint": "蓝调版画", "neon": "霓虹", "graffiti": "街头涂鸦", "cyberpunk": "赛博朋克",
    "aurora": "极光", "inkwash": "水墨", "picasso": "毕加索", "pixel": "像素风",
    "papercut": "剪纸", "cartoon": "卡通", "woodcut": "木刻版画", "ukiyoe": "浮世绘",
    "sketch": "素描", "minimal": "素描极简", "cyanotype": "蓝晒水彩", "inkcarve": "墨影刻痕",
    "tiktok": "tiktok", "sunrise": "日出印象", "rust": "铁锈", "dither": "抖动像素",
    "retro": "复古", "psy": "迷幻",
    "copper": "铜浮雕", "nobel": "诺贝尔金箔", "mosaic": "彩色玻璃马赛克",
}
ENUMS = {
    "style": list(STYLES), "effect": ["direct", "line", "comic", "emboss"],
    "color": ["curve", "gray", "duotone", "colordot"],
    "curve": list(LUT_TABLES), "view": ["original", "processed", "wipe", "side_by_side"],
    "video_mode": ["1080p30", "720p30", "480p30", "480p60"],
}
RANGES = {"ai_strength": (0, 100), "fx_strength": (0, 100), "saturation": (0, 200), "wipe": (4, 96)}
DEFAULT = dict(style="vangogh", effect="direct", color="curve", curve="identity",
               view="wipe", video_mode="480p30", ai_strength=100, fx_strength=100,
               saturation=100, wipe=50, keep_color=False,
               keep_box=[120, 255, 0, 120, 0, 120], paused=False)

SCENE_KEYS = {"brightness_mean", "brightness_std", "saturation_mean", "warmth",
              "dominant_colors", "histogram"}
SCENE_NUMBERS = {"brightness_mean": (0, 255), "brightness_std": (0, 128),
                 "saturation_mean": (0, 255), "warmth": (-1.0, 1.0)}


class Invalid(ValueError):
    pass


def capabilities(lite=False):
    tables = LUT_TABLES if lite else {k: {**v, "curves64": LUT_CURVES64[k]} for k, v in LUT_TABLES.items()}
    return {"profile": "software-demo-v1", "simulated": True, "enums": ENUMS,
            "ranges": RANGES, "booleans": ["paused", "keep_color"], "keep_box_note": "keep_box=[Rmin,Rmax,Gmin,Gmax,Bmin,Bmax] RGB 长方体；改盒经保色页取色流程实现，动作序列取决于画面内容", "styles": STYLES,
            "tables": tables, "recipes": RECIPES,
            "note": "全部为软件模拟；表×颜色模式为解耦组合。网络及第一板命令接收未实现。"}


def model_capabilities():
    """喂给 LLM 的能力视图：不含 curves64 数值（那是前端渲染数据，对模型是纯噪音）。"""
    return {"profile": "software-demo-v1", "enums": ENUMS, "ranges": RANGES,
            "booleans": ["paused", "keep_color"], "keep_box_note": "keep_box=[Rmin,Rmax,Gmin,Gmax,Bmin,Bmax] RGB 长方体；改盒经保色页取色流程实现，动作序列取决于画面内容", "styles": STYLES,
            "tables": {k: {"cn": v["cn"], "kind": v["kind"], "desc": v["desc"]}
                       for k, v in LUT_TABLES.items()},
            "recipes": RECIPES}


def validate_patch(patch):
    if not isinstance(patch, dict) or not 1 <= len(patch) <= len(DEFAULT):
        raise Invalid("changes 必须是非空参数对象")
    for key, value in patch.items():
        if key not in DEFAULT:
            raise Invalid(f"设备未声明能力：{key}")
        if key in ENUMS and (not isinstance(value, str) or value not in ENUMS[key]):
            raise Invalid(f"{key} 不支持该值")
        if key in RANGES:
            lo, hi = RANGES[key]
            if type(value) is not int or not lo <= value <= hi:
                raise Invalid(f"{key} 必须为 {lo}–{hi} 的整数")
        if key in ("paused", "keep_color") and type(value) is not bool:
            raise Invalid(f"{key} 必须为布尔值")
        if key == "keep_box":
            if not isinstance(value, list) or len(value) != 6 or                any(type(v) is not int or not 0 <= v <= 255 for v in value):
                raise Invalid("keep_box 应为 6 个 0–255 整数 [Rmin,Rmax,Gmin,Gmax,Bmin,Bmax]")
            if value[0] > value[1] or value[2] > value[3] or value[4] > value[5]:
                raise Invalid("keep_box 每个通道的 min 不能大于 max")
    return copy.deepcopy(patch)


def validate_recipe(recipe_id):
    if recipe_id not in RECIPE_IDS:
        raise Invalid(f"未登记的配方：{recipe_id}")
    found = next(r for r in RECIPES if r["id"] == recipe_id)
    return copy.deepcopy(found["changes"])


def validate_scene(stats):
    """校验前端上报的画面统计（Canvas 端计算，服务端只做有界校验）。"""
    if not isinstance(stats, dict) or not stats or set(stats) - SCENE_KEYS:
        raise Invalid("画面统计字段无效")
    missing = SCENE_KEYS - set(stats)
    if missing:
        raise Invalid("画面统计缺少字段：" + "、".join(sorted(missing)))
    clean = {}
    for key, (lo, hi) in SCENE_NUMBERS.items():
        value = stats[key]
        if type(value) not in (int, float) or not lo <= value <= hi:
            raise Invalid(f"{key} 数值越界")
        clean[key] = round(float(value), 2)
    colors = stats["dominant_colors"]
    if not isinstance(colors, list) or not 1 <= len(colors) <= 4:
        raise Invalid("dominant_colors 应为 1–4 项")
    parsed = []
    total = 0.0
    for item in colors:
        if not isinstance(item, dict) or set(item) != {"rgb", "ratio"}:
            raise Invalid("主色条目格式无效")
        rgb = item["rgb"]
        if not isinstance(rgb, list) or len(rgb) != 3 or any(type(c) is not int or not 0 <= c <= 255 for c in rgb):
            raise Invalid("主色 RGB 无效")
        ratio = item["ratio"]
        if type(ratio) not in (int, float) or not 0 <= ratio <= 1:
            raise Invalid("主色占比无效")
        parsed.append({"rgb": rgb, "ratio": round(float(ratio), 3)})
        total += ratio
    if total > 1.05:
        raise Invalid("主色占比合计超过 1")
    clean["dominant_colors"] = parsed
    hist = stats["histogram"]
    if not isinstance(hist, list) or len(hist) != 16 or any(type(v) not in (int, float) or v < 0 for v in hist):
        raise Invalid("直方图应为 16 个非负数")
    hist_total = sum(hist)
    if hist_total <= 0:
        raise Invalid("直方图无效")
    clean["histogram"] = [round(float(v) / hist_total, 4) for v in hist]
    return clean


def scene_summary(stats):
    """把画面统计转成中文描述，供 Agent 与对话引用。"""
    bright = stats["brightness_mean"]
    std = stats["brightness_std"]
    sat = stats["saturation_mean"]
    warmth = stats["warmth"]
    tone = "偏暗" if bright < 85 else ("偏亮" if bright > 170 else "亮度适中")
    contrast = "低对比" if std < 28 else ("高对比" if std > 62 else "对比适中")
    colorfulness = ("画面接近黑白" if sat < 24 else
                    ("色彩克制" if sat < 70 else ("色彩浓郁" if sat < 150 else "高饱和")))
    hue = ("整体偏暖" if warmth > 0.08 else ("整体偏冷" if warmth < -0.08 else "冷暖均衡"))
    parts = [f"画面{tone}（平均亮度 {bright:.0f}/255）", contrast, colorfulness, hue]
    if stats["dominant_colors"]:
        tops = sorted(stats["dominant_colors"], key=lambda c: -c["ratio"])[:3]
        named = "、".join(f"#{c['rgb'][0]:02x}{c['rgb'][1]:02x}{c['rgb'][2]:02x}（{c['ratio']*100:.0f}%）" for c in tops)
        parts.append("主色：" + named)
    shadows = sum(stats["histogram"][:5])
    highlights = sum(stats["histogram"][11:])
    if shadows > 0.4:
        parts.append("暗部占比高")
    if highlights > 0.35:
        parts.append("高光占比高")
    return "；".join(parts) + "。"


def validate_plan(raw):
    if not isinstance(raw, dict) or set(raw) != {"reply", "changes"}:
        raise Invalid('模型应只返回 {"reply": "说明", "changes": {}}')
    if not isinstance(raw["reply"], str) or len(raw["reply"]) > 1200:
        raise Invalid("模型说明无效或过长")
    if raw["changes"] == {}:
        return raw
    return {"reply": raw["reply"], "changes": validate_patch(raw["changes"])}


def parse_model(text):
    if not isinstance(text, str) or len(text) > 16000:
        raise Invalid("模型输出为空或过长")
    text = text.strip()
    if text.startswith("```") and text.endswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)[:-3].strip()
    def unique(pairs):
        result = {}
        for k, v in pairs:
            if k in result:
                raise Invalid("JSON 存在重复字段")
            result[k] = v
        return result
    try:
        raw = json.loads(text, object_pairs_hook=unique)
    except (ValueError, TypeError) as e:
        raise Invalid("模型返回的不是完整、唯一字段的 JSON") from e
    return validate_plan(raw)


def recommend_from_scene(stats):
    """基于画面统计的离线推荐规则：暗→日落，冷→暖调，过饱和→银盐，寡淡→霓虹。"""
    picks = []
    if stats["brightness_mean"] < 90:
        picks.append(("sunset", "画面偏暗，日落映射的橙金高光段可以点亮主体"))
    if stats["warmth"] < -0.08:
        picks.append(("warm_film", "画面偏冷，暖色表的曲线能把色温拉回来"))
    if stats["saturation_mean"] > 145:
        picks.append(("mono_memory", "画面饱和度偏高，银盐记忆的低饱和黑白更耐看"))
    if stats["saturation_mean"] < 30:
        picks.append(("neon", "画面接近黑白，酸性霓虹表配灰度配色能注入强色彩"))
    if not picks:
        picks.append(("teal_orange_cine", "画面曝光与色彩均衡，青橙影调最稳妥地增加电影感"))
    recipe_id, reason = picks[0]
    found = next(r for r in RECIPES if r["id"] == recipe_id)
    changes = validate_recipe(recipe_id)
    validate_patch(changes)
    others = ""
    if len(picks) > 1:
        others = "也可以试试：" + "、".join(
            next(r["cn"] for r in RECIPES if r["id"] == rid) for rid, _ in picks[1:2]) + "。"
    return {"reply": f"根据画面分析，我推荐「{found['cn']}」：{reason}。已直接应用。{others}",
            "changes": changes}


RECIPE_WORDS = [
    (["霓虹", "赛博", "acid"], "neon"), (["青版", "印相", "蓝晒"], "cyanotype"),
    (["日落", "熔金", "晚霞"], "sunset"), (["红外", "热感", "热成像"], "infrared"),
    (["森绿", "墨绿", "森林"], "forest"), (["青橙影调", "teal"], "teal_orange_cine"),
    (["暖调胶片", "暖色胶片"], "warm_film"), (["旧忆", "泛黄旧照"], "aged_paper"),
    (["银盐", "记忆黑白"], "mono_memory"), (["底片", "反相", "负片"], "negative_film"),
]
# 单表/单模式词（配方未命中时逐项应用）
TABLE_WORDS = [
    (["暖色"], "warm"), (["泛黄"], "aged"), (["泛绿"], "verdant"),
    (["记忆"], "memory"), (["青橙调", "青橙表"], "cine"),
    (["酸性霓虹", "霓虹表"], "neon"), (["青版表", "青版表"], "cyan"),
    (["森绿表"], "forest"), (["红外伪彩"], "thermal"), (["日落表"], "sunset"),
    (["青橙影调表"], "duotone"), (["负片表"], "invert"),
]


def apply_recipe(recipe_id, state):
    changes = validate_recipe(recipe_id)
    validate_patch(changes)
    return changes


def offline_plan(text, state, scene_stats=None):
    """Explicit demo rules; never presented as a real language model."""
    lower = text.lower()
    if scene_stats and ("推荐" in text or "适合" in text) and ("画面" in text or "分析" in text):
        plan = recommend_from_scene(scene_stats)
        validate_patch(plan["changes"])
        return plan
    unsupported = [w for w in ["对比度", "亮度", "gamma", "锐化", "模糊", "保存", "推流", "缩放"] if w in lower]
    if unsupported:
        return {"reply": "当前能力未开放：" + "、".join(unsupported) + "。未执行整条请求；可试试配方卡或灰度配色模式。", "changes": {}}
    # 配方优先：命中即整体应用，不改写其余参数。
    for words, recipe_id in RECIPE_WORDS:
        if any(w in lower or w in text for w in words):
            changes = apply_recipe(recipe_id, state)
            found = next(r for r in RECIPES if r["id"] == recipe_id)
            return {"reply": f"应用配方「{found['cn']}」：{found['desc']}。", "changes": changes}
    patch = {}
    style_words = [
        (["梵高", "星空"], "vangogh"), (["波普漫画", "波普"], "popcomic"), (["糖果"], "candy"),
        (["点彩"], "pointillism"), (["蓝调版画", "蓝调"], "blueprint"),
        (["涂鸦"], "graffiti"), (["赛博朋克"], "cyberpunk"), (["极光"], "aurora"),
        (["水墨"], "inkwash"), (["毕加索"], "picasso"), (["像素"], "pixel"),
        (["剪纸"], "papercut"), (["卡通"], "cartoon"), (["木刻"], "woodcut"), (["浮世绘"], "ukiyoe"),
        (["素描极简"], "minimal"), (["素描"], "sketch"), (["蓝晒"], "cyanotype"), (["墨影"], "inkcarve"),
        (["tiktok"], "tiktok"), (["日出"], "sunrise"), (["铁锈"], "rust"), (["抖动"], "dither"),
        (["复古"], "retro"), (["迷幻"], "psy"),
    ]
    for words, value in style_words:
        if any(w in text for w in words):
            patch["style"] = value
    for words, key, value in [
        (["素描", "线稿"], "effect", "line"), (["漫画"], "effect", "comic"),
        (["浮雕"], "effect", "emboss"), (["关闭特效", "无特效"], "effect", "direct"),
        (["灰度配色", "渐变映射"], "color", "gray"), (["双调网点", "双调"], "color", "duotone"),
        (["彩色网点", "网点"], "color", "colordot"), (["正常颜色", "曲线模式"], "color", "curve"),
        (["左右对比", "擦除对比"], "view", "wipe"), (["并排"], "view", "side_by_side"),
        (["全屏", "只看效果"], "view", "processed"), (["只看原图"], "view", "original"),
        (["暂停", "冻结"], "paused", True), (["恢复", "继续播放"], "paused", False),
        (["保留颜色", "局部保色", "keep"], "keep_color", True),
        (["保留红色", "保红色"], "keep_box", [120, 255, 0, 120, 0, 120]),
        (["保留绿色", "保绿色"], "keep_box", [0, 130, 60, 255, 0, 130]),
        (["保留蓝色", "保蓝色"], "keep_box", [0, 110, 0, 110, 130, 255]),
        (["关闭保色", "取消保色", "关闭保留"], "keep_color", False),
    ]:
        if any(word in text for word in words):
            patch[key] = value
    for words, table in TABLE_WORDS:
        if any(word in text for word in words):
            patch["curve"] = table
    if "黑白" in text and "curve" not in patch:
        patch["curve"] = "memory"
        patch["color"] = "curve"
    for mode in ENUMS["video_mode"]:
        if mode in lower:
            patch["video_mode"] = mode
    for words, key in [("(?:AI|ai|风格|强度)", "ai_strength"), ("(?:FX|fx|特效)", "fx_strength"), ("饱和度", "saturation"), ("分割(?:线)?", "wipe")]:
        match = re.search(words + r"[^，,。；;\d]{0,8}(-?\d+)\s*[%％]?", text)
        if match:
            patch[key] = int(match[1])
    if "降低强度" in text and "ai_strength" not in patch:
        patch["ai_strength"] = max(0, state["ai_strength"] - 20)
    if "提高强度" in text and "ai_strength" not in patch:
        patch["ai_strength"] = min(100, state["ai_strength"] + 20)
    if "重置" in text:
        patch = copy.deepcopy(DEFAULT)
    if not patch:
        return {"reply": "离线规则未识别这条请求。试试“赛博霓虹”“青版印相”“落日熔金”，或在设置中连接 DeepSeek。", "changes": {}}
    validate_patch(patch)
    return {"reply": "已生成演示控制计划。" + ("暂停期间参数先保存，恢复后用于后续画面。" if state["paused"] else ""), "changes": patch}


def frame(kind, seq, payload):
    if len(payload) > 54:
        raise Invalid("UART payload 超长")
    data = struct.pack("<BBHH", 1, kind, seq & 65535, len(payload)) + payload
    return b"\xa5\x5a" + data + struct.pack("<H", binascii.crc_hqx(data, 0xffff))


def decode_frame(data):
    if len(data) < 10 or data[:2] != b"\xa5\x5a":
        raise Invalid("UART 同步/长度错误")
    version, kind, seq, length = struct.unpack("<BBHH", data[2:8])
    if version != 1 or length > 54 or len(data) != length + 10:
        raise Invalid("UART 版本/长度错误")
    if binascii.crc_hqx(data[2:-2], 0xffff) != struct.unpack("<H", data[-2:])[0]:
        raise Invalid("UART CRC 错误")
    return kind, seq, data[8:-2]


def uart_preview(patch, state, seq=0):
    """Only proven registry IDs. Missing mappings stay explicit, never raw MMIO."""
    state = {**state, **patch}
    commands, missing = [], []
    if "video_mode" in patch:
        commands.append((0x10, bytes([ENUMS["video_mode"].index(state["video_mode"])])))
    if "keep_color" in patch:
        commands.append((0x25, bytes([23])))  # UI_ACTION KEEP_TOGGLE
    if "effect" in patch or "color" in patch:
        commands.append((0x13, struct.pack("<BH", {"direct": 0, "line": 4, "comic": 5, "emboss": 6}[state["effect"]], ENUMS["color"].index(state["color"]))))
    # Native scaling must be established against the selected first-board build.
    # Emit percentages only in semantic JSON; no speculative i32 native values.
    for key in patch:
        if key not in {"video_mode", "effect", "color", "keep_color"}:
            missing.append(key)
    rows = []
    for i, (kind, payload) in enumerate(commands):
        wire = frame(kind, seq + i, payload)
        decode_frame(wire)
        rows.append({"type": f"0x{kind:02X}", "hex": wire.hex(" ").upper(), "bytes": len(wire)})
    return {"frames": rows, "unmapped": missing, "complete": not missing,
            "note": "仅展示已登记 UART v1 编码；其余语义待固件适配。软件模拟直接应用语义对象，不冒充 UART 硬件执行。"}


# 64 点源曲线（0..63），供前端按硬件语义做真渲染；与 lut_library .json 同源。
LUT_CURVES64 = {"identity":[[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63],[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63],[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63]],"warm":[[0,0,0,1,1,2,2,3,4,4,5,6,7,8,9,9,10,11,12,14,15,16,18,19,21,22,24,25,27,28,30,32,33,35,36,38,39,41,42,44,45,47,48,50,51,52,53,54,55,56,57,58,58,59,60,60,61,62,62,63,63,63,63,63],[2,2,2,3,3,4,4,5,5,6,9,10,11,11,11,12,13,14,14,15,15,17,18,20,22,24,25,28,28,29,30,31,34,35,35,35,35,36,38,40,42,42,44,46,47,47,48,49,50,52,53,54,54,55,55,56,56,57,59,60,60,60,60,63],[4,4,5,8,8,8,8,8,9,11,15,15,15,15,15,15,15,15,15,15,15,15,16,18,20,22,24,26,26,26,26,28,32,32,32,32,32,32,32,34,35,36,38,40,41,41,41,42,43,45,46,46,47,48,48,49,50,51,52,54,54,54,54,62]],"aged":[[2,3,3,4,5,5,6,6,7,8,9,10,10,11,12,13,14,15,16,18,19,20,22,23,24,26,27,29,30,31,33,34,35,37,38,39,40,41,42,43,44,45,46,47,47,48,49,50,50,51,52,52,53,54,54,55,56,56,57,58,59,59,60,60],[3,3,3,5,5,6,6,6,7,8,11,11,12,13,13,14,15,16,16,17,17,19,20,22,24,26,27,30,30,30,32,33,35,36,36,36,36,37,39,40,42,42,43,45,46,46,46,47,48,50,51,51,51,52,52,53,53,54,56,58,58,58,59,63],[7,7,7,10,10,10,10,10,10,12,15,15,15,15,15,15,15,15,15,15,15,15,17,18,19,21,23,24,24,24,24,26,29,29,29,29,29,29,30,31,32,32,34,35,36,36,36,36,37,39,39,39,40,41,41,42,43,43,45,46,46,46,46,54]],"verdant":[[0,0,0,1,2,2,3,4,4,5,6,7,7,8,9,10,11,11,12,13,14,15,16,17,18,20,21,22,23,24,25,27,28,30,30,31,32,34,35,36,37,39,40,41,42,43,44,45,46,48,49,49,50,51,52,53,53,54,55,56,57,57,58,59],[2,2,2,4,4,5,5,5,6,7,9,10,10,11,11,12,13,13,13,14,14,15,17,18,19,21,22,24,24,25,25,27,29,30,30,30,30,31,32,34,35,36,37,39,40,40,41,42,43,45,46,46,47,48,48,49,49,50,52,54,54,54,55,59],[5,5,6,8,8,8,8,8,8,10,12,12,12,12,12,12,12,12,12,12,12,12,13,14,15,17,18,18,18,18,18,20,22,22,22,22,22,22,22,23,23,24,25,27,27,27,27,28,29,30,31,31,32,32,33,34,35,35,37,39,39,39,39,47]],"memory":[[4,5,5,5,6,6,7,7,8,8,9,9,10,11,11,12,12,13,15,15,16,17,18,18,19,19,20,20,21,24,25,25,25,25,28,31,33,35,36,38,39,41,42,44,45,46,47,48,49,50,50,51,52,52,53,53,54,54,55,55,56,56,57,57],[7,7,8,9,9,10,10,11,11,12,14,14,15,15,15,16,17,17,17,18,18,19,20,21,22,23,24,25,26,26,27,28,29,31,31,31,32,33,34,36,37,38,39,41,42,42,42,43,44,46,46,47,47,48,48,49,49,50,51,53,53,53,53,56],[8,8,9,11,11,11,11,11,12,14,16,16,17,17,17,17,17,17,17,17,17,17,18,19,20,22,24,24,24,24,24,26,29,30,30,30,30,30,30,32,33,33,34,36,37,37,37,37,38,40,40,40,41,42,42,42,43,44,45,46,46,46,46,53]],"cine":[[0,0,0,0,0,1,1,2,2,3,4,5,6,7,8,8,9,10,12,13,14,15,16,17,18,18,19,19,20,24,25,25,25,25,29,32,35,37,39,41,42,44,46,48,49,50,52,53,54,55,55,56,57,58,58,59,60,60,61,61,62,63,63,63],[2,2,3,5,5,6,6,7,7,9,11,11,12,13,13,14,15,15,15,16,17,18,19,20,21,23,24,25,26,26,27,29,30,32,32,32,33,35,37,38,40,41,42,44,45,45,46,47,48,50,51,51,52,53,53,54,54,55,57,59,59,59,59,63],[3,3,4,7,7,7,7,8,8,10,14,14,14,14,14,14,14,14,14,14,14,15,16,17,19,21,23,24,24,24,24,26,30,30,30,30,30,30,31,33,34,35,36,39,39,39,39,40,41,43,43,43,44,45,45,46,47,48,49,50,50,50,50,58]],"neon":[[3,5,6,8,9,11,12,14,15,17,18,20,21,23,24,27,30,33,35,38,41,44,46,49,52,55,57,57,53,50,46,42,39,35,32,28,25,21,17,14,10,7,3,0,3,6,9,12,15,18,21,24,27,30,33,35,38,41,44,47,50,53,56,59],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,5,8,11,15,18,21,24,27,31,34,37,40,43,47,50,53,53,54,54,55,55,56,56,57,58,58,59,59,60,60,61,62,62,63,63,63],[9,11,12,14,16,17,19,21,22,24,26,27,29,31,32,32,32,32,31,31,31,31,31,31,30,30,30,31,32,33,35,36,37,38,40,41,42,44,45,46,48,49,50,51,50,50,49,48,48,47,46,46,45,44,44,43,42,42,41,40,40,39,38,38]],"cyan":[[2,2,3,3,3,4,4,4,5,5,5,5,6,6,6,7,7,7,8,8,8,9,9,9,10,10,11,12,13,14,15,17,18,19,20,21,22,23,25,26,27,28,29,30,31,32,34,35,36,37,39,40,42,43,45,46,48,49,50,52,53,55,56,58],[3,4,4,5,6,7,7,8,9,9,10,11,12,12,13,14,14,15,16,17,17,18,19,19,20,21,22,23,24,26,27,28,29,30,32,33,34,35,36,38,39,40,41,42,44,45,46,47,48,49,50,51,51,52,53,54,55,56,56,57,58,59,60,60],[8,9,10,11,12,13,14,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,32,33,34,35,36,37,38,38,39,40,41,42,43,44,45,46,47,48,48,49,50,51,52,53,54,55,55,56,56,57,57,58,58,59,59,60,60,61,61,62,62,63]],"forest":[[2,3,3,4,4,5,5,6,6,6,7,7,8,8,9,9,9,10,10,11,11,12,12,12,13,13,14,14,15,15,15,16,16,17,17,18,19,21,22,24,25,27,28,30,31,33,34,36,37,39,40,42,43,45,46,48,49,51,52,54,55,57,58,60],[6,6,7,7,8,9,9,10,11,11,12,12,13,14,14,15,16,16,17,18,18,19,19,20,21,21,22,23,23,24,25,25,26,26,27,28,29,30,31,32,33,34,35,37,38,39,40,41,42,43,44,45,46,47,48,50,51,52,53,54,55,56,57,58],[4,4,5,5,6,6,7,7,8,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,15,16,16,17,17,18,18,19,19,20,20,21,22,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,42,43,44,45,46,47,48,49,50]],"thermal":[[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,21,23,24,26,28,29,31,32,34,36,37,39,40,42,43,44,45,47,48,49,50,51,53,54,55,56,58,59,60,61,62,63,63,63,63,63,63,63,63,63,63,63,63,63,63],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,2,2,3,3,4,4,5,5,5,6,6,7,8,9,10,12,13,15,16,17,19,20,21,23,24,26,27,28,30,31,33,35,38,40,42,44,47,49,51,53,56,58,60,62],[2,3,3,4,4,4,5,5,5,6,6,6,7,7,7,8,8,8,8,7,7,7,7,6,6,6,6,6,5,5,5,5,5,5,5,5,6,6,6,6,7,7,7,7,8,8,8,8,8,9,12,15,19,22,25,29,32,36,39,43,46,49,53,56]],"sunset":[[6,7,8,10,11,12,13,14,16,17,18,19,20,22,23,24,25,26,28,29,30,31,32,34,35,36,37,39,40,41,42,44,45,46,48,49,50,51,53,54,55,56,57,57,58,58,59,59,60,60,61,61,62,62,63,63,63,63,63,63,63,63,63,63],[2,2,3,3,3,3,4,4,4,4,5,5,5,6,6,6,6,7,7,7,7,8,8,9,10,10,11,12,13,14,15,15,16,17,18,19,20,20,21,22,23,24,25,26,28,29,30,32,33,34,35,37,38,39,41,42,44,46,48,50,52,54,57,59],[11,11,12,12,12,12,13,13,13,14,14,14,15,15,15,15,16,16,16,17,17,17,17,17,17,17,16,16,16,15,15,15,14,14,14,13,13,13,12,12,12,11,12,12,13,13,13,14,14,15,15,16,16,16,17,17,19,22,24,27,30,32,35,38]],"duotone":[[2,2,3,3,4,4,4,5,5,6,6,7,7,7,8,8,9,9,9,10,10,11,11,11,12,12,13,13,14,14,14,15,16,17,19,20,22,24,25,27,28,30,31,33,34,36,37,39,41,42,44,45,47,48,50,51,53,54,56,58,59,61,62,63],[10,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,26,27,27,28,28,28,29,29,30,30,30,31,31,32,32,32,33,33,34,34,34,35,35,36,36,36,37,37,38],[12,12,13,13,14,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,27,27,27,27,27,26,26,25,25,25,24,24,24,23,23,23,22,22,21,21,21,20,20,20,19,19,19,18,18,17,17,17,16,16]],"invert":[[63,62,61,60,59,58,57,56,55,54,53,52,51,50,49,48,47,46,45,44,43,42,41,40,39,38,37,36,35,34,33,32,31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0],[63,62,61,60,59,58,57,56,55,54,53,52,51,50,49,48,47,46,45,44,43,42,41,40,39,38,37,36,35,34,33,32,31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0],[63,62,61,60,59,58,57,56,55,54,53,52,51,50,49,48,47,46,45,44,43,42,41,40,39,38,37,36,35,34,33,32,31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0]]}
