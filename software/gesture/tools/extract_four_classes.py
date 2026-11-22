"""把 HaGRID 512p 镜像的 parquet 分片抽成本方案需要的"四类"图片目录。

只抽四类需要的源类别，其余类别（12 个其他手势类）与 COCO 负样本一律不动：
    手掌   <- palm(9) + stop(13)
    握拳   <- fist(2)
    其它   <- no_gesture(6)
    左滑/右滑 <- 稍后由"手掌"按 21 关键点方向角筛分生成（见设计文档 §6.2），本脚本不生成

图片字节直接落盘（parquet 里就是原始 JPEG），不重新编码；文件名沿用数据集原始文件名
（image.path），便于后续与官方 annotations_with_landmarks 做 join。

用法：
    python extract_four_classes.py --shards ../demo/samples/hf_probe --out ../dataset
"""
import argparse
import os
import re
import sys

import pyarrow.parquet as pq

# HaGRID class label -> 本方案类目录名
# 手背：凡是"手背朝镜头"的类别统一归到一个类（stop_inverted=张开手的手背，其余是并指手型的手背）
LABEL_MAP = {
    # 手掌：掌心朝镜头、五指伸直（张开或并拢）
    9: ('手掌', 'palm'),
    13: ('手掌', 'stop'),
    # 手背：手背朝镜头、五指伸直（两指手势不算、背面的拳不算）
    14: ('手背', 'stop_inverted'),
    # 握拳
    2: ('握拳', 'fist'),
    # 其它：没有手 + 其余全部手势（都是本方案的硬负样本）
    6: ('其它', 'no_gesture'),
    0: ('其它', 'call'),
    1: ('其它', 'dislike'),
    3: ('其它', 'four'),
    4: ('其它', 'like'),
    5: ('其它', 'mute'),
    7: ('其它', 'ok'),
    8: ('其它', 'one'),
    10: ('其它', 'peace'),
    11: ('其它', 'peace_inverted'),
    12: ('其它', 'rock'),
    15: ('其它', 'three'),
    16: ('其它', 'three2'),
    17: ('其它', 'two_up'),
    18: ('其它', 'two_up_inverted'),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shards', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                     '../demo/samples/hf_probe'),
                    help='含 shardN.parquet 的目录')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '../dataset'),
                    help='输出目录')
    ap.add_argument('--limit', type=int, default=0, help='每个源类别最多抽多少张（0=不限，用于试跑）')
    ap.add_argument('--only', default='', help='只抽这些本方案类（逗号分隔，如 --only 手背）；默认全抽')
    args = ap.parse_args()

    shards = sorted(f for f in os.listdir(args.shards)
                    if re.fullmatch(r'shard\d+\.parquet', f))
    if not shards:
        sys.exit(f'在 {args.shards} 下没找到 shardN.parquet')

    only = {x.strip() for x in args.only.split(',') if x.strip()}
    active = {k: v for k, v in LABEL_MAP.items() if not only or v[0] in only}
    for our_cls, src_cls in active.values():
        os.makedirs(os.path.join(args.out, our_cls, src_cls), exist_ok=True)

    written = {}
    for shard in shards:
        path = os.path.join(args.shards, shard)
        pf = pq.ParquetFile(path)
        n_rows = 0
        for g in range(pf.metadata.num_row_groups):
            table = pf.read_row_group(g, columns=['image', 'label'])
            images = table.column('image').to_pylist()
            labels = table.column('label').to_pylist()
            for rec, label in zip(images, labels):
                if label not in active:
                    continue
                our_cls, src_cls = active[label]
                if args.limit and written.get(src_cls, 0) >= args.limit:
                    continue
                name = rec['path'] if isinstance(rec, dict) else f'{shard}_row{n_rows}.jpg'
                dest = os.path.join(args.out, our_cls, src_cls, os.path.basename(name))
                with open(dest, 'wb') as f:
                    f.write(rec['bytes'] if isinstance(rec, dict) else rec)
                written[src_cls] = written.get(src_cls, 0) + 1
            n_rows += table.num_rows
        print(f'  {shard}: {n_rows} 行处理完, 累计 {written}')

    print('\n抽取完成：')
    for (our_cls, src_cls) in active.values():
        print(f'  {our_cls}/{src_cls}: {written.get(src_cls, 0)} 张')
    print(f'  合计 {sum(written.values())} 张 -> {os.path.abspath(args.out)}')


if __name__ == '__main__':
    main()
