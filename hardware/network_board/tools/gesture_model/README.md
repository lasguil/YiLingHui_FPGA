
# 手势模型导出与整数参考

板 2 随包的部署模型位于 [固件模型目录](../../software/gesture_firmware/model/)。

若要生成参考权重和整数仿真数据，请准备 `hand_landmark_lite_int8.onnx`，放到仓库根目录下的 `software/gesture/models/reference/`。安装 NumPy、ONNX 后，从当前目录按顺序运行 `python extract_model.py`、`python build_ops.py` 和 `python pack_hw.py`。参考结果写入当前目录下的 `build/`。整机工程仍使用随包的部署模型。可选的摄像头整数参考演示还需要 CUDA PyTorch。
