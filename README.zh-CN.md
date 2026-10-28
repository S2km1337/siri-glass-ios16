# Siri Glass for iOS 16.5

[English](README.md) | 简体中文

iOS 27 风格的 Siri 液态玻璃水滴,移植到 iOS 16.5 越狱设备上:唤起 Siri 时,水滴从灵动岛滴出,折射背后的屏幕内容,随 Siri 的状态和你的声音变化,替换掉底部原来的 Siri 光球。

基于 [haplollc/SiriGlass](https://github.com/haplollc/SiriGlass)(MIT)。本项目以 MIT 协议开源,见 [LICENSE](LICENSE)。

- **目标设备:** iPhone 14 Pro,iOS 16.5,Dopamine 2.4.9 roothide(其它带灵动岛的 iOS 16 设备理论上可用,未测试)。
- **当前版本:** 0.1.35(半成品,已停止开发)。Siri 的文字进灵动岛:水滴随文字长成 iOS 27 式玻璃,逐词模糊淡入,底部原文字隐藏;天气等原生卡片放进玻璃;状态栏随玻璃让路;上滑玻璃或灵动岛可随时收起。

## 效果

模拟器录制。玻璃变宽时状态栏会像灵动岛展开那样先缩小、再逐个退让,收起时原路回来(真机上由插件接管系统状态栏,模拟器里是 Demo 自己模拟的同样逻辑):

| 文字逐词出现,玻璃随文字生长 | 原生卡片(如天气)放进玻璃 |
|---|---|
| ![](media/demo-caption.gif) | ![](media/demo-card.gif) |

| 一行字 | 两行字 |
|---|---|
| ![](screenshots/caption-1line.png) | ![](screenshots/caption-2lines.png) |

| 普通灵动岛 | 被实时活动撑宽的灵动岛 |
|---|---|
| ![](screenshots/island-normal.png) | ![](screenshots/island-wide.png) |

![](screenshots/card-in-glass.png)

## 致谢

- [haplollc/SiriGlass](https://github.com/haplollc/SiriGlass)(MIT):水滴的原始实现。
- [DnV1eX/LiquidGlassKit](https://github.com/DnV1eX/LiquidGlassKit):折射着色器的思路参考(没有拷贝代码)。

## 组成

| 目录 | 作用 |
|---|---|
| [src/SiriGlass](src/SiriGlass) | 上游 SiriGlass 的 fork:降到 iOS 16,用 Metal 自绘玻璃和折射 |
| [src/SiriGlassHost](src/SiriGlassHost) | Swift 动态库,把 SiriGlass 包成 Objective-C 可调用的 `SGHost` |
| [src/SiriGlassTweak](src/SiriGlassTweak) | SpringBoard tweak:接管 Siri 球,驱动水滴,打包成 deb |
| [src/SiriGlassTweak/SiriGlassPrefs](src/SiriGlassTweak/SiriGlassPrefs) | PreferenceLoader 设置面板(开关 tweak) |
| [tools](tools) | 构建脚本 |

## 构建

需要 Xcode、[roothide Theos](https://github.com/roothide/theos)(放在 `~/theos-roothide`)和 `ldid`。

```bash
tools/build_deb.sh
```

产物在 `src/SiriGlassTweak/packages/`。

## 安装

可以直接下载 [Releases](../../releases) 里的 deb(roothide / arm64e,iOS 16.5 测试)。把 deb 传到手机,用 Filza 或 Sileo 安装,然后注销或重新越狱。设置面板在「设置 → Siri Glass」,可以开关 tweak。

## 用法

- 唤起 Siri:侧边按钮 /「嘿 Siri」,或**从灵动岛向下滑**。
- 实时活动把灵动岛撑宽时,水滴会加宽并上移,让玻璃盖住岛的两个上角。

## BUG 自测

**这是半成品,不再继续开发。** 下面是已知有问题的地方,欢迎接手:

- 玻璃里的原生卡片(如"打开闹钟"的闹钟列表)在真机上不能滑动、点选:触摸到不了卡片,原因没查清(见 src/SiriGlassTweak/Tweak.x 里 SiriSharedUICompactResultView 相关代码)。
- 折射背景靠「截图时排除玻璃窗口」刷新,只在 iOS 16.5 / Dopamine 上测过;换机型、换系统要重测。
- 从灵动岛下滑唤起 Siri、上滑收起:手势可能和系统灵动岛自己的手势冲突。
- 岛被实时活动撑宽时水滴显得扁。
- 设置面板需要 PreferenceLoader。
- 调试日志默认关闭,打开方式见 [src/SiriGlassTweak/README.md](src/SiriGlassTweak/README.md)。
