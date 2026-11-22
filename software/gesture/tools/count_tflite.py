"""统计 TFLite 模型的算子清单、逐层 MAC 与常量参数量。只读模型，不执行推理。"""
import sys
import numpy as np
import tflite


def tensor_shape(sg, idx):
    t = sg.Tensors(idx)
    return t, t.ShapeAsNumpy()


def main(path):
    model = tflite.Model.GetRootAsModel(open(path, 'rb').read(), 0)
    sg = model.Subgraphs(0)

    const_params = 0
    for i in range(sg.TensorsLength()):
        t = sg.Tensors(i)
        buf = model.Buffers(t.Buffer())
        if buf is not None and buf.DataLength() > 0:
            shape = t.ShapeAsNumpy()
            const_params += int(np.prod(shape)) if len(shape) else 1

    def shape_of(idx):
        t = sg.Tensors(idx)
        return [int(x) for x in t.ShapeAsNumpy()]

    print(f'== {path}')
    print('inputs :', [shape_of(i) for i in sg.InputsAsNumpy()])
    print('outputs:', [(i, shape_of(i)) for i in sg.OutputsAsNumpy()])

    total_mac = 0
    op_hist = {}
    rows = []
    for i in range(sg.OperatorsLength()):
        op = sg.Operators(i)
        code = model.OperatorCodes(op.OpcodeIndex()).BuiltinCode()
        name = tflite.opcode2name(code)
        op_hist[name] = op_hist.get(name, 0) + 1
        ins = [int(op.Inputs(j)) for j in range(op.InputsLength())]
        outs = [int(op.Outputs(j)) for j in range(op.OutputsLength())]
        mac = 0
        if name == 'CONV_2D' and len(ins) >= 2:
            filt = shape_of(ins[1])          # [out_c, kh, kw, in_c]
            osh = shape_of(outs[0])          # [1, oh, ow, out_c]
            opt = tflite.Conv2DOptions()
            opt.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
            groups = opt.Group() if hasattr(opt, 'Group') else 1
            groups = groups if groups else 1
            mac = osh[1] * osh[2] * filt[0] * filt[1] * filt[2] * (filt[3] // groups)
        elif name == 'DEPTHWISE_CONV_2D' and len(ins) >= 2:
            filt = shape_of(ins[1])          # [1, kh, kw, ch]
            osh = shape_of(outs[0])
            mac = osh[1] * osh[2] * filt[3] * filt[1] * filt[2]
        elif name == 'FULLY_CONNECTED':
            filt = shape_of(ins[1])          # [out, in]
            mac = filt[0] * filt[1]
        total_mac += mac
        rows.append((name, mac, shape_of(ins[0]), shape_of(outs[0])))

    for name, mac, ish, osh in rows:
        tag = f'{mac/1e6:8.3f} MMAC' if mac else ' ' * 13
        print(f'{name:26s} {tag}  {ish} -> {osh}')
    print(f'-- 算子直方图: {op_hist}')
    print(f'-- 常量参数: {const_params:,} ({const_params/1024:.1f} KiB 若 INT8)')
    print(f'-- 全模型 MAC: {total_mac:,} = {total_mac/1e6:.3f} M')


if __name__ == '__main__':
    for p in sys.argv[1:]:
        main(p)
        print()
