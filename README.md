# 暗灯（MagOff）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://github.com/NEX-coding/magoff)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-MagSafe%203-blue.svg)](https://github.com/NEX-coding/magoff)

**Turn off the MagSafe charger LED. Sleep in the dark.**

菜单栏小工具：一键关掉 MagSafe 充电器指示灯。可选在 ChatGPT / Codex 回复或系统通知时绿橙交叉闪。

<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" alt="暗灯 icon">
</p>

## Download

从 [Releases](https://github.com/NEX-coding/magoff/releases) 下载 `AnDeng-MagOff-*-macos-arm64.zip`，解压后把 **暗灯.app** 拖到「应用程序」。

首次打开若被拦截：右键 App → **打开**。（当前 ad-hoc 签名；欢迎帮做正式公证。）

## One-liner

> Mac 充电时那颗绿/橙灯半夜太亮？用「暗灯」一键关掉。只改灯，不改充电。

> Turn off the MagSafe charger LED on Apple Silicon MacBooks. Charging stays the same.

## Requirements

- Apple Silicon MacBook（MagSafe 3）
- MagSafe cable **with an LED**（纯 USB-C 头没有这颗灯）
- macOS 14+

## Features

| 选项 | 效果 |
|------|------|
| **关闭指示灯** | 灯灭 |
| 系统默认 | 交还 macOS（充满绿、充电橙） |
| 强制绿灯 / 橙灯 | 固定颜色 |
| GPT/Codex 回复时闪烁 | AI 回完 → 交叉闪；切到 ChatGPT/Cursor 即停 |
| 所有系统通知都闪烁 | 需辅助功能权限 |

第一次选模式会要管理员密码，安装很小的 LaunchDaemon；插拔充电器后会自动再应用一次。

## Keyboard backlight?

**No effect.** MagOff only writes MagSafe SMC key `ACLC`. Keyboard backlight uses a different path (`CoreBrightness`). Charging power and battery management are untouched.

## How it works

| `ACLC` | Meaning |
|--------|---------|
| 0 | System control |
| 1 | Off |
| 3 | Green |
| 4 | Amber |
| 6 / 7 | Amber blink |

## Build from source

```bash
./scripts/build.sh
open dist/暗灯.app

# shareable zip + dmg
./scripts/package.sh
```

## Promo kit

多平台文案（X / 小红书 / 抖音）：见 [`promo/`](promo/).

## Uninstall

菜单「卸载后台服务…」，或：

```bash
sudo launchctl bootout system/com.nex.magoff.helper 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.nex.magoff.helper.plist
sudo rm -f "/Library/Application Support/MagOff/magoff-helper"
```

## License

[MIT](LICENSE)
