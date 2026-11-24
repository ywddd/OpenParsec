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
| Press and hold | Hold the left button and drag, including files (Touchpad or Direct) |
| 2-finger drag | Scroll at 1×; pan the zoomed viewport when zoomed |
| 1-finger drag | Move the cursor (Touchpad); pan the zoomed viewport (Direct) |
| Pinch | Zoom around the fingers, with Pinch to Zoom on |
| 3-finger tap | On-screen keyboard |
| Swipe in from the left edge | Stream menu, when the buttons are hidden |

The stream screen's keyboard toolbar keeps keyboard, pointer/direct mode, and viewport reset in a compact 44-point action cluster. If **Show Keyboard Button** is off, that cluster is hidden; pointer/direct mode, viewport reset, right-click, text/key input mode, zoom, and display mode remain in the stream menu, and the keyboard can still be toggled with a three-finger tap. The first connection shows a one-time gesture hint. Disconnect remains outside the scrollable menu area on small screens.

Direct mode semantics are explicit: at 1× a tap places and clicks the host pointer at that remote position; once zoomed, a one-finger drag pans the visible viewport instead of moving the pointer or dragging a remote item. Press and hold still holds the left button for file drags. Pinch to Zoom uses the saved preference and is off by default; enable it in Settings or the stream menu.

## Mouse & Keyboard
Hardware mice and keyboards are supported.

### 手机悬浮鼠标与操作面板（中文版本）

右下角“操作”入口在竖屏展开底部面板、横屏展开右侧面板，保留声音、仅观看、画面复位、设置、键盘、显示桌面、窗口切换及退出。退出需要确认；仅观看阻止鼠标、滚轮、文字、键盘和手柄输入。

虚拟鼠标有独立左/右/中键、滚轮与移动区。按住左键并滑动该手指，或用另一指滑动移动区，可拖动远端项目；抬起、取消、收起或离开串流释放按钮。顶端手柄只移动浮层位置，右下手柄调整大小，关闭按钮收起为可重新展开的圆形入口。操作面板展开期间暂时隐藏鼠标，避免控件覆盖；收起面板后恢复。

窗口快捷键沿用设置中的主机粘贴平台选择：Windows 为 Win+D / Alt+Tab，macOS 为 Cmd+F3 / Cmd+Tab。本轮根据用户提供的 UU 截图和 RustDesk 公开交互设计独立用 Swift/UIKit 实现，不复制其源码或品牌素材。原生输入法、按住拖动及键盘/旋转布局仍需手机实测。

Option Key as Command can be turned on in Settings for Mac hosts.

### Text input and host clipboard (Chinese version)

The keyboard has two modes, selectable in **设置 → 输入方式** or the stream menu. **文字输入** receives native IME composition, Chinese candidates, English, emoji, and multi-character paste, then commits the final text once through the host clipboard and triggers an explicit paste shortcut. It never reads or writes the phone's clipboard and does not require global clipboard sync to be enabled, but it does replace the host clipboard. The default paste shortcut is Windows `Ctrl+V`; choose macOS `Cmd+V` in Settings when the host needs it.

**按键输入** sends ASCII characters and named special keys for host IMEs, games, and applications that block paste. Native Chinese candidates or other non-ASCII text from the phone's IME are rejected in this mode; to type Chinese, enable a Chinese IME on the Windows host and use key mode there. The current Parsec SDK keyboard path sends key codes rather than Unicode text, so it cannot inject arbitrary Chinese characters. If the host application blocks clipboard paste, use key mode or enable the host's clipboard handling; sending a paste command does not guarantee every application or password field accepted it.

## Game Controllers
One controller is supported. Pressing any trigger during a stream registers it with Parsec. The host needs the virtual USB driver installed.

## Video
Metal is the default renderer, OpenGL can be picked in Settings.

The stream pauses in the background, resumes on return and reconnects after a network drop.

### 横屏自适应（中文版本）

竖屏保持原生等比显示。横屏“自适应”优先请求手机实际像素分辨率（例如 2622×1206），仅超过 3840×2160 时按比例限缩。渲染以实际可见视频帧为准，只做一次等比适配；不裁剪桌面，也不拉伸画面。

主机必须支持这个显示模式。Parsec Windows 主机设置中选择分辨率跟随客户端，并使用主机的同一个账号连接；SDK 的连接分辨率通常仅对第一个所有者连接有效。在主机高级配置中，`server_resolution_x` 和 `server_resolution_y` 均为 `0` 表示跟随客户端，均为 `65535` 表示保留主机分辨率。修改后重启主机 Parsec，再重新连接。

优先在运行中的主机界面选择 `Use Client Resolution`，不要直接编辑运行中的 `config.json`：Parsec 会用内存中的旧设置覆盖文件。必须手动改文件时，先完全退出主机 Parsec，备份配置后再将这两项设为 `0`，最后重新启动。此操作会断开现有远程连接，应在主机本地操作或保留备用连接。

已有支持目标模式的虚拟显示器可以直接使用。Parsec 官方 VDD 的虚拟显示功能需相应 Warp/Teams 权益；仅安装驱动不代表已启用虚拟屏。客户端无法创建主机显示驱动不支持的任意分辨率。

串流菜单会显示“等待 / 已匹配 / 未匹配”，并报告请求分辨率、实际视频帧、解码器状态以及画面矩形。实际画面未匹配时，仍完整等比显示，并提示主机设置；不会用裁剪或拉伸伪装成功。

构建中的数值回归验证截图尺寸、SDK 与可见帧尺寸不一致的坐标映射、偶数取整和请求超时。源码审核和编译通过不代替手机实机验收。

输入法候选、第三方键盘、放大后的四向拖动、长按拖文件、右键、复位和键盘开关仍需在真机分别验证；不同主机系统、主机剪贴板设置和应用粘贴策略可能不同，不能以编译成功代替运行时验收。

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
