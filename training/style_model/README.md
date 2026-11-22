
# 风格模型研究源码

本目录包含 V2-E FactorizedShuffle 网络定义，以及训练、感知蒸馏和量化分析代码。网络定义见 [model_v2de.py](model_v2de.py)，训练与精修策略见 [train_texture_continuation.py](train_texture_continuation.py) 和 [refine_policy.json](refine_policy.json)。

复现训练需要另行准备数据集、教师权重和 CUDA 环境，随包提供的是部分研究源码。部署使用 [风格资产目录](../../assets/README.md) 中的模型和 LUT。重新打包部署资产可以直接使用核心板的 [生成工具](../../hardware/main_board/tools/generate_model_assets.py)。
