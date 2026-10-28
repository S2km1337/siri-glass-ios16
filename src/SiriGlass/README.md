# SiriGlass (iOS 16 fork)

A SwiftUI view of the Siri liquid-glass drop that pours out of the Dynamic Island, redrawn with Metal so it runs on iOS 16.

This is a fork of [haplollc/SiriGlass](https://github.com/haplollc/SiriGlass) (MIT). What changed, and the new API used by the tweak, is in [FORK.md](FORK.md). The original library's usage docs (states, audio feeds, recipes) are in the upstream README; the API shown there still applies.

## Run the demo

```bash
open Demo/SiriGlassDemo.xcodeproj    # Orb | iPhone picker; tap anywhere to talk
```

Environment variables for stills and scripted takes are listed at the top of `Demo/SiriGlassDemo/DemoConfig.swift`, for example:

```bash
SIMCTL_CHILD_SIRIGLASS_STAGE=iPhone SIMCTL_CHILD_SIRIGLASS_CAPTION_SCRIPT=zh xcrun simctl launch booted <bundle id>
```

## Shader

The glass is a runtime-compiled Metal shader. Edit `Sources/SiriGlass/SiriGlass.metal.txt`, then regenerate the Swift copy:

```bash
python3 Scripts/embed_shader.py
```

`DropField` in `Drop/DropFrame.swift` mirrors the shader's shape formula in Swift (used for the outline mask); change both together.

## License

MIT, see [LICENSE](LICENSE). Original work © Haplo LLC.
