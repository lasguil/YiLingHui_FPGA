"""统计 ONNX 模型的算子清单、逐层 MAC 与参数量。只读模型，不执行推理。"""
import sys
from collections import Counter

import numpy as np
import onnx
from onnx import numpy_helper

CONV_OPS = {'Conv', 'ConvInteger', 'QLinearConv', 'QLinearConvTranspose'}
MAC_OPS = CONV_OPS | {'Gemm', 'MatMul', 'QLinearMatMul'}


def shape_of(vi):
    dims = []
    for d in vi.type.tensor_type.shape.dim:
        dims.append(d.dim_value if d.HasField('dim_value') else 0)
    return dims


def main(path):
    m = onnx.shape_inference.infer_shapes(onnx.load(path), strict_mode=False)
    g = m.graph
    init = {i.name: numpy_helper.to_array(i) for i in g.initializer}
    shapes = {vi.name: shape_of(vi) for vi in list(g.input) + list(g.value_info) + list(g.output)}

    def sh(name):
        if name in shapes and any(shapes[name]):
            return shapes[name]
        if name in init:
            return list(init[name].shape)
        return shapes.get(name, [])

    print(f'== {path}')
    print('inputs :', [(i.name, shape_of(i)) for i in g.input if i.name not in init])
    print('outputs:', [(o.name, shape_of(o)) for o in g.output])

    total = 0
    params = sum(int(v.size) for v in init.values())
    hist = Counter()
    detail = []
    for node in g.node:
        hist[node.op_type] += 1
        mac = 0
        if node.op_type in CONV_OPS:
            # weights: Conv/ConvInteger -> input[1]; QLinearConv -> input[3]
            wname = node.input[3] if node.op_type == 'QLinearConv' else node.input[1]
            w = init.get(wname)
            if w is not None:
                oc = w.shape[0]
                kh, kw = w.shape[2], w.shape[3]
                ic_total = w.shape[1]
                out_shape = sh(node.output[0])
                groups = 1
                for a in node.attribute:
                    if a.name == 'group':
                        groups = a.i
                if len(out_shape) == 4 and all(out_shape[1:]):
                    # 按权重输出通道数判断 NCHW / NHWC
                    if out_shape[1] == oc:
                        oh, ow = out_shape[2], out_shape[3]
                    else:
                        oh, ow = out_shape[1], out_shape[2]
                elif len(out_shape) == 4:
                    # NCHW with dynamic spatial: derive from input if possible
                    oh, ow = sh(node.input[0])[2], sh(node.input[0])[3]
                else:
                    oh = ow = 0
                mac = oh * ow * oc * kh * kw * ic_total
        elif node.op_type in ('Gemm', 'MatMul', 'QLinearMatMul'):
            w = init.get(node.input[1])
            if w is not None:
                mac = int(w.size)
        total += mac
        if mac:
            detail.append((node.op_type, mac, node.input[0], node.output[0]))

    for op, mac, i, o in detail:
        print(f'{op:16s} {mac/1e6:9.3f} MMAC  {sh(i)} -> {sh(o)}')
    print('-- 算子直方图:', dict(hist))
    print(f'-- 初始器参数: {params:,} ({params/1024/1024:.2f} MiB)')
    print(f'-- 全模型 MAC: {total:,} = {total/1e6:.3f} M')


if __name__ == '__main__':
    for p in sys.argv[1:]:
        main(p)
        print()
