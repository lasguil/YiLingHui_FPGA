# 部署资产

`styles/deploy` 按模型槽顺序存放 29 个风格的部署包，`styles` 下的 `.pt` 是生成器核验用的原始检查点。`luts/lut` 存放 12 个颜色表。核心板使用的模型与 LUT 合并包位于 `hardware/main_board/assets`。

在核心板工程目录运行 `tools/generate_model_assets.py` 可重新生成合并包，并核对模型、量化参数、校验和及 LUT。`additional_catalog.json` 和 `additional_bundle.bin` 是后 3 个模型的打包校验数据，不改变其在 29 模型目录中的位置。
