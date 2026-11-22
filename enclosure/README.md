# 外壳建模与加工文件

## 亚克力切割

下面三份 DXF 是最终切割图，单位为毫米。发给亚克力加工商家时，请把三份一起发过去。

- [1.dxf](top/1.dxf)
- [2.dxf](top/2.dxf)
- [3.dxf](top/3.dxf)

## 3D 打印

小圆柱件用 [sheel-Body.stl](top/sheel-Body.stl) 切片打印。同一个零件也提供 [STEP 文件](top/sheel-Body.step) 和 [可编辑的 FreeCAD 源文件](top/sheel.FCStd)。

## FreeCAD 装配

打开 [camera_top.FCStd](top/camera_top.FCStd) 查看装配模型。它会引用上一级目录里的零件文件，请保留 `enclosure/` 的目录结构。
