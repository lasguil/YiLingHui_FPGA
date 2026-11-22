# 核心板固件

这里包含 RISC-V 裸机控制固件。运行 `build_multi_style_24k.bat` 可生成固件；它依赖 Efinity 2026.1 RISC-V 工具链和脚本中指定的 Python。

风格和 LUT 数据位于仓库根目录 `assets`；`../tools/generate_model_assets.py` 检查并打包 29 个模型和 12 个 LUT。工程使用的模型/LUT 合并包位于 `../assets/model_bundle_29x16k_lut12.bin`。
