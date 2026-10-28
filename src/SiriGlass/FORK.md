# 本 fork 的改动(iOS 16 / 越狱 tweak 用)

上游:[haplollc/SiriGlass](https://github.com/haplollc/SiriGlass)(MIT)。这些改动尚未提交到 git(`git status` 可见)。

## 降到 iOS 16

- `Package.swift`、Demo 工程:最低版本 17.0 → 16.0。
- `MicListener.swift`:iOS 16 用 `AVAudioSession.requestRecordPermission` 申请麦克风。
- `DemoView.swift`:改用 iOS 14 的单参数 `onChange`。

## 自绘玻璃(替代 iOS 17 的 `colorEffect` 和 iOS 26 的 `glassEffect`)

- `Drop/DropMetalView.swift`(新):`MTKView` 一次绘制完成玻璃折射和墨色光效。
  - 背景素材:宿主通过 `SiriGlassBackdrop.provider` 提供整屏截图(tweak 用这个);否则截取本窗口,每秒 2 次、1 倍分辨率。
- `SiriGlass.metal.txt`:原 `Shaders/SiriGlass.metal` 改成普通顶点/片元着色器,片元里先按水滴轮廓折射背景(折射模型参考 LiquidGlassKit 的思路,未拷贝代码),再叠加原来的墨色和光。
- `Shaders/SiriGlassShader.swift`:由 `Scripts/embed_shader.py` 从 `.metal.txt` 生成,运行时编译。这样 dylib 不需要资源包。**改着色器后必须重新生成。**
- `DropFrame.swift`:去掉 SwiftUI `Shader`;`DropField` 仍然是着色器形状公式的 Swift 镜像。

## 供 tweak 使用的新接口

- `SiriGlassBackdrop.provider` / `.refreshInterval`:宿主提供的折射素材。
- `SiriGlassIsland.override`:宿主测得的灵动岛实时位置(实时活动会撑大它)。`DropEngine` 会让水滴至少比岛宽 32pt。
- `DropGeometry.wideIsland(width:)`:按岛宽给出额外的上移量和横向余量;普通岛返回原来的 `lift=5`、`margin=16`,所以普通岛几何不变。

## 外形

- `DropGeometry.lift = 5`:水滴整体比上游上移 5pt,让玻璃盖住普通灵动岛的两个上角。形状本身与上游一致。
- 宽岛(实时活动):`DropGeometry.wideIsland(width:)` 返回 `lift = 5 + 0.10 * (width - 126.67)`、`margin = 16 + 0.04 * (width - 126.67)`。`DropEngine.render` 用这个 `lift` 把水滴整体上移(高度不变)、用 `margin` 加宽,让水滴自己的弧线盖住岛的上角。190×37.33pt 时按 `DropField` 算,角离玻璃边缘最近约 7.4pt。

## 不再适用的上游说明

上游 README 里的"iOS 17+"、"Liquid Glass on iOS 26"、SPM 资源包等说明,对本 fork 不再准确。
