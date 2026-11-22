# 1D LUT 仓库

2026 全国大学生嵌入式芯片与系统设计竞赛（FPGA 赛道）· 易灵绘作品用 1D 调色表库。
12 张表 = 5 张人工评审的电影调色（RocketStock 源）+ 7 张强风格化（6 张自研渐变映射 + 1 张负片）。

## 目录约定

每个 LUT 一个目录，命名 `序号-中文名-英文名`：

- `table.mem` — 硬件表：768 行、每行 2 位十六进制（1 字节取低 6 位），顺序 **R[256] → G[256] → B[256]**，与 `IPX_TABLE_DATA` 装载顺序一致（地址 `{phase[1:0], index[7:0]}`）。
- `meta.json` — 元数据：`id`/`name_zh`/`name_en`、`kind`（grade 调色 / grade_bw 黑白调色 / gradient 渐变映射 / curve 曲线特效）、`mode`（推荐颜色模式：0=RGB 曲线、1=灰度配色）、来源与许可、`metrics`（fit/look/step，0..63 域）、`curves64`（64 点源曲线）、`format` 说明。
- `preview.jpg/png` — 三联预览：左原图（480p 校准视频帧）、右板端 1D 效果。

`mode` 与表是**解耦**的：任何表都可在 4 种颜色模式下使用，效果由组合决定；`meta.mode` 只是该表设计时的推荐读法。gradient 表配 mode 1 即渐变映射。

## 总索引

| 序号 | 中文名 | 英文名 | 类别 | 推荐模式 | 来源 | fit | look | step |
|------|--------|--------|------|----------|------|-----|------|------|
| 01 | 暖色 | warm | 调色 | mode 0 | RocketStock 35 | 2.87 | 3.63 | 8 |
| 02 | 泛黄 | aged | 调色 | mode 0 | RocketStock 35 | 2.8 | 2.33 | 8 |
| 03 | 泛绿 | verdant | 调色 | mode 0 | RocketStock 35 | 2.35 | 4.91 | 8 |
| 04 | 记忆 | memory | 调色·黑白 | mode 0 | RocketStock 35 | 2.88 | 3.21 | 7 |
| 05 | 青橙 | cine | 调色 | mode 0 | RocketStock 35 | 3.56 | 3.61 | 8 |
| 06 | 酸性霓虹 | neon | 渐变映射 | mode 1 | 自研参数生成 | — | — | — |
| 07 | 青版 | cyan | 渐变映射 | mode 1 | 自研参数生成 | — | — | — |
| 08 | 森绿 | forest | 渐变映射 | mode 1 | 自研参数生成 | — | — | — |
| 09 | 红外伪彩 | thermal | 渐变映射 | mode 1 | 自研参数生成 | — | — | — |
| 10 | 日落 | sunset | 渐变映射 | mode 1 | 自研参数生成 | — | — | — |
| 11 | 青橙影调 | duotone | 渐变映射 | mode 1 | 自研参数生成 | — | — | — |
| 12 | 负片 | invert | 曲线特效 | mode 0 | 自研参数生成 | — | — | — |

## 曲线生成方法（可复现）

1. 调色类：原始 3D LUT（.cube）对 COCO 采样集拟合（`D:\weight\main_256\images` 随机 60 张、seed=7、393 万像素），按输入 6bit 电平取每通道条件均值；
2. PAVA 保序回归防色带（渐变映射/负片为有意非单调，不做）；
3. 量化 6bit（0..63）；
4. 展开为 256 项/通道：硬件命中地址 `{v, v[5:4]}`（即 `4v + (v>>4)`，共 64 个）精确放置，其余地址折线延拓。

生成脚本与中间产物：`tmp/lut_import/`（import_luts.py / stylized_luts.py 等）。

## 许可与出处

- **01–05**：RocketStock 35 Free LUTs（经 PremiumBeat 博客分发）——免费使用，禁止转售/再分发原资产；量化曲线为衍生使用，保留本记录。
- **06–11**：本项目自研参数生成（渐变 stop 插值 + PAVA），无外部版权。
- **12**：本项目自研。

## 硬件接入

- 装载路径 1（builtin）：把 `meta.json` 的 `curves64` 转为 C 数组，按 `IPX_TABLE_DATA` 逐字节写（放宽 `preset>1` 检查）。
- 装载路径 2（DDR）：`table.mem` 打包放 DDR，`sp_load_color_table` 经 IPX read DMA 加载；`style_control.c` 的 `table_directory[]` 增加条目，UI 显示名取 `name_zh`（或 `name_en`）。
- 装载流程与颜色模式解耦；gradient 表建议配合 `cfg.color=1`（灰度配色）使用。
