# SiriGlassHost

一个只有一个文件的 Swift 包,编成 **arm64e 动态 framework**,供 SiriGlassTweak 在 SpringBoard 里 `dlopen` 使用。它把 SiriGlass 的 SwiftUI 水滴包装成 Objective-C 可以调用的类。

## `SGHost`(`@objc(SGHost)`,全部在主线程调用)

| 方法 | 作用 |
|---|---|
| `attachToWindow:` | 把水滴覆盖层直接加到窗口上(不挂父 VC),返回是否成功 |
| `detach` | 状态归零并移除覆盖层 |
| `setState:` | `0` 空闲、`1` 在听、`2` 思考 |
| `setPower:` | 音量,0…1 或 dB(负数,约 -50…0) |
| `setIslandX:y:width:height:` | 灵动岛的实时位置;宽度为 0 表示清除 |
| `setBackdropProvider:` | 提供整屏截图的 block,作为折射素材 |

水滴出现期间,`SGRaiser` 用 `CADisplayLink` 每帧强制刷新 SwiftUI,并每 0.1 秒把覆盖层置顶。

## 构建

由仓库根目录的 `tools/build_deb.sh` 调用:

```bash
xcodebuild -scheme SiriGlassHost -destination 'generic/platform=iOS' -sdk iphoneos \
  -configuration Release -derivedDataPath /tmp/sghost ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

产物:`/tmp/sghost/Build/Products/Release-iphoneos/PackageFrameworks/SiriGlassHost.framework`。只依赖系统库,不带资源包(着色器以字符串形式编进代码)。
