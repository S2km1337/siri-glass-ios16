# SiriGlassTweak

SpringBoard tweak(Theos,roothide 方案),把 iOS 16 Siri 底部的光球换成 SiriGlass 的液态玻璃水滴。

## 原理

iOS 16 的 Siri 光球是 SpringBoard 里的 `SUICOrbView`(位于 `SBAssistantWindow`)。tweak 保留它作为 Siri 状态的来源,但把它设成几乎透明:

- `setMode:` / `_setMode:`:Siri 状态,`1` 听、`2` 想、`3` 回答、`0` 结束。
- `setPower:` / `setPowerLevel:`:麦克风音量(dB)。
- 灵动岛跟踪:每帧读 `SBSystemApertureContainerView` 的实际显示位置,让水滴适配被实时活动撑宽的岛。
- 下滑手势:在 `SBSystemApertureContainerView` 上装 `UIPanGestureRecognizer`,向下 24pt 后调用 `SiriActivationService -activationRequestFromSimpleActivation:7`(系统原本的 Siri 唤起路径)。
- 设置开关:读 `com.local.siriglasstweak` 的 `Enabled`;关闭时恢复旧球并 `detach` 水滴。

水滴本身由 `SiriGlassHost.framework` 绘制,运行时 `dlopen`(`/Library/Frameworks/SiriGlassHost.framework`,经 `jbroot()` 转换路径)。

## 文件

- `Tweak.x`:全部 hook、下滑手势、设置开关。
- `control`:包信息,**每次发新版都要升 `Version`**。
- `SiriGlassTweak.plist`:注入过滤,只注入 `com.apple.springboard`。
- `SiriGlassPrefs/`:PreferenceLoader 设置面板(单独 Theos bundle)。
- `layout/Library/PreferenceLoader/Preferences/SiriGlass.plist`:设置入口。
- `layout/Library/Frameworks/SiriGlassHost.framework`:由 `tools/build_deb.sh` 生成并签名,不要手改。
- `layout/Library/PreferenceBundles/SiriGlassPrefs.bundle`:由 `tools/build_deb.sh` 从 `SiriGlassPrefs/` 生成,不要手改。

## 构建

在仓库根目录运行 `tools/build_deb.sh`。它会先编 framework,再编 `SiriGlassPrefs.bundle` 并拷进 `layout/`,最后打 deb。单独打包(不重编 framework / 设置面板):

```bash
export THEOS=~/theos-roothide
make package
```

注意:`make package` 不会自动重编设置面板;改了 `SiriGlassPrefs/` 后要用 `tools/build_deb.sh`。

设置面板的 `PSListController` 用 `-undefined dynamic_lookup` 在运行时从 Preferences 解析;不要把 `Preferences` 加进 `PRIVATE_FRAMEWORKS`(iPhoneOS SDK 没有它的 stub,链接会报 `framework 'Preferences' not found`)。

## 运行时配置

- `/var/mobile/siriglass-modes.txt`(可选):覆盖 mode 到水滴状态的映射,例如 `0=idle 1=listening 2=thinking 3=listening`。每 2 秒重新读取一次。
- 设置面板:「设置 → Siri Glass」,开关写入 `com.local.siriglasstweak` 的 `Enabled`,默认开。

## 调试

默认不写日志。把 `com.local.siriglasstweak` 的 `DebugLog` 设为 true 后,事件会写到 `/var/tmp/siriglass-debug.log`(SpringBoard)和 Siri 的 `Library/Logs/CrashReporter/Assistant/CardLogs/siriglass-siri.log`(Siri.app);内容只有事件和文字长度,不含你说的话。也可以用 Console.app / `idevicesyslog` 过滤 `SiriGlass`。

Siri.app 和 SpringBoard 之间用同一个 CardLogs 目录里的几个 plist 传文字和卡片尺寸(Siri.app 沙盒只允许写这里),Siri 结束时会被清空。
