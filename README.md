# <p align="center">![icon_transparent.png](OpenParsec/Assets.xcassets/IconTransparent.imageset/icon_transparent.png) ![OpenParsec](OpenParsec/Assets.xcassets/LogoShadow.imageset/logo_shadow.png)</p>

OpenParsec is a simple, open-source Parsec client for iOS/iPadOS written in Swift using the SwiftUI framework and the Parsec SDK. This project is not affiliated with Parsec.

## Downloads
<p>
<a href="https://stikstore.app/altdirect/?url=https://github.com/hugeBlack/OpenParsec/releases/download/nightly/altstore.json" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200">
</a>
<a href="https://github.com/hugeBlack/OpenParsec/releases/download/nightly/OpenParsec.ipa" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200">
</a>
</p>

These are nightly builds from main. Tagged versions are on the [Releases](https://github.com/hugeBlack/OpenParsec/releases) page.

The .ipa works with AltStore, SideStore, LiveContainer and TrollStore. LiveContainer does not check sources for new builds. For updates, tap install in the source and replace the existing app to get the newest build.

OpenParsec is built against iOS 14 and later.

OpenParsec will never support App Store distribution as it bundles the Parsec SDK, which can't be redistributed under App Store policies.

## Touch Control
Touch modes can be set in Settings or the stream menu. Touchpad moves the cursor like a laptop trackpad, Direct clicks where the finger lands.

| Gesture | Action |
| --- | --- |
| Tap | Click |
| 2-finger tap | Right click |
| Press and hold | Drag (Touchpad) |
| 2-finger drag | Scroll |
| Pinch | Zoom, with Pinch to Zoom on |
| 3-finger tap | On-screen keyboard |
| Swipe in from the left edge | Stream menu, when the buttons are hidden |

## Mouse & Keyboard
Hardware mice and keyboards are supported.

Option Key as Command can be turned on in Settings for Mac hosts.

## Game Controllers
One controller is supported. Pressing any trigger during a stream registers it with Parsec. The host needs the virtual USB driver installed.

## Video
Metal is the default renderer, OpenGL can be picked in Settings.

The stream pauses in the background, resumes on return and reconnects after a network drop.

### 横屏自适应（中文版本）

竖屏保持原生等比显示。横屏“自适应”优先请求手机实际像素分辨率（例如 2622×1206），仅超过 3840×2160 时按比例限缩。渲染以实际可见视频帧为准，只做一次等比适配；不裁剪桌面，也不拉伸画面。

主机必须支持这个显示模式。Parsec Windows 主机设置中选择分辨率跟随客户端，并使用主机的同一个账号连接；SDK 的连接分辨率通常仅对第一个所有者连接有效。在主机高级配置中，`server_resolution_x` 和 `server_resolution_y` 均为 `0` 表示跟随客户端，均为 `65535` 表示保留主机分辨率。修改后重启主机 Parsec，再重新连接。

已有支持目标模式的虚拟显示器可以直接使用。Parsec 官方 VDD 的虚拟显示功能需相应 Warp/Teams 权益；仅安装驱动不代表已启用虚拟屏。客户端无法创建主机显示驱动不支持的任意分辨率。

串流菜单会显示“等待 / 已匹配 / 未匹配”，并报告请求分辨率、实际视频帧、解码器状态以及画面矩形。实际画面未匹配时，仍完整等比显示，并提示主机设置；不会用裁剪或拉伸伪装成功。

构建中的数值回归验证截图尺寸、SDK 与可见帧尺寸不一致的坐标映射、偶数取整和请求超时。源码审核和编译通过不代替手机实机验收。

## Troubleshooting
Error codes are explained on Parsec's [error codes page](https://support.parsec.app/hc/en-us/articles/32381281333012-All-Error-Codes).

For "Couldn't reach the host" (-6023) inside LiveContainer, turn on Local Network for LiveContainer in the Settings app.

Microphone passthrough isn't supported by the last public release of the Parsec SDK.

## Lag / Low Bitrate Issue
For sudden lag or a bitrate that hardly goes over 10 Mbps, run Steam Link's network test. Constant spikes in the graph mean a problem with Apple that the app can do little about, see [here](https://github.com/moonlight-stream/moonlight-ios/issues/627) for more discussion.

## Building
Clone with `--recursive` for the Parsec SDK submodule, open `OpenParsec.xcodeproj`, set a team and bundle identifier under Signing & Capabilities, and build. CI builds with Xcode 26.2.

## Contributing
See [CONTRIBUTING](CONTRIBUTING.md).

## License
[GPL-3.0](LICENSE)
