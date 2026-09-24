<div align="right">

[English](README.md) | **简体中文**

</div>

<div align="center">

<img src="docs/icon.png" width="140" alt="Kumone" />

# Kumone

**雲の音 — 原生 macOS 网易云音乐客户端**

SwiftUI 编写 · 直连网易云真实 API · Sparkle 自动更新

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue?logo=apple)](#构建)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-LGPL--3.0--only-orange)](LICENSE)

<table>
  <tr>
    <td><img src="docs/screenshot-home.png" alt="推荐" /></td>
    <td><img src="docs/screenshot-nowplaying.png" alt="沉浸播放页" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshot-daily.png" alt="每日推荐" /></td>
    <td><img src="docs/screenshot-lyrics.png" alt="歌词面板" /></td>
  </tr>
</table>

</div>

## 名字由来

**Kumone** 取自日语 **雲の音**（*kumo no ne*，「云的声音」），缩合为一个词 —— **雲音**（假名写作 くもね，读作 *kumone*）。呼应网易「云」音乐的「云」字：从云端飘落到你耳边的音乐。

## 功能

- 🔐 **扫码登录** — 网易云 App 扫码，Cookie 本地持久化，自动续期
- 🏠 **推荐** — 每日推荐、私人漫游、心动模式、推荐歌单、雷达歌单（私人雷达系列，按账号个性化）、排行榜、新碟上架、推荐歌手
- 🧭 **精选** — 分类歌单（精品 / 官方 / 排行榜 / 场景分类）无限滚动
- 🎵 **播放** — AVPlayer 引擎，标准 ~ Hi-Res 音质可选（黑胶 VIP 可播无损，自动回落），随机 / 单曲循环 / 列表循环，下一首播放队列，灰色歌曲识别
- 🚗 **CarPlay（iOS，按需开启）** — Now Playing、分类音乐库、播放队列与搜索模板已写入二进制；激活需 [Apple 授权的 CarPlay 音频能力](https://developer.apple.com/contact/carplay/)，大多数账号不会被授予。默认关闭以保证开源源码树可直接编译，详见下方[启用 CarPlay](#启用-carplayios)
- 🔓 **灰色歌曲解锁** — 原生实现 UnblockNeteaseMusic 核心音源（pyncmd / 酷我 / 酷狗），无版权或试听歌曲自动匹配第三方音源
- 🖼 **沉浸播放页** — 封面取色渐变背景 + 大封面 + 大字同步歌词（点击播放条封面进入，Esc 退出）
- 📻 **私人漫游** — 沉浸式 FM 页面，不喜欢 / 切歌
- 📝 **歌词** — 侧边玻璃面板，逐行同步 + 翻译，点击跳转
- 🪟 **桌面歌词** — LyricsX 风格悬浮置顶歌词（含翻译），可拖动、位置持久化，所有空间与全屏应用上可见
- 📚 **音乐库** — 我喜欢的音乐、创建 / 收藏的歌单、收藏专辑、关注歌手、最近播放、音乐云盘
- ✏️ **歌单管理** — 新建 / 删除 / 收藏歌单、添加 / 移除歌曲、红心
- 🔍 **搜索** — 综合 / 单曲 / 歌手 / 专辑 / 歌单，热搜词占位
- ⌨️ **系统集成** — 媒体键 / 控制中心（Now Playing）、听歌打卡、退出后恢复播放队列
- 🌐 **多语言** — 简体中文与英文界面，跟随系统语言；Sparkle 更新说明双语

## 安装

要求 macOS 15+（Universal：Apple Silicon 与 Intel 均支持）。

### Homebrew

```bash
brew install owo-network/brew/kumone --cask
```

### 手动下载

从 [Releases](https://github.com/missuo/kumone/releases/latest) 下载最新的
`Kumone-x.y.z.zip`，解压后拖入「应用程序」。

应用已使用 Developer ID 签名并通过 Apple 公证，内置 Sparkle 自动更新
（菜单栏 Kumone → 检查更新…）。

### iOS / iPadOS（侧载）

每次发版都会附带**无签名**的 `Kumone-iOS-x.y.z.ipa`（iOS 16+）。Kumone 是非官方客户端，不会上架 App Store 或 TestFlight，请用侧载工具以自己的 Apple ID 签名安装 —— [AltStore](https://altstore.io)、[SideStore](https://sidestore.io)、[Sideloadly](https://sideloadly.io) 或 Xcode 均可。iOS 26+ 的 Tab Bar 使用系统原生 Liquid Glass；iOS 16–25 则回退为仿制的玻璃栏。

更新：iOS 应用无法自我替换。设置 → 关于 → **检查更新** 会提示是否有新版本并给出下载链接，下载新 IPA 后用同一工具重新安装即可，登录状态与设置会保留。AltStore / SideStore 也可通过 source 自动追踪发布：添加源地址 <https://github.com/missuo/kumone/releases/latest/download/altstore.json>，之后每次发版都会自动出现在更新列表里。

#### 应用内自动更新（仅限 TrollStore / 巨魔）

在装有 **[TrollStore](https://github.com/opa334/TrollStore)（巨魔）** 的设备上，Kumone 可自我更新：设置 → 关于 → **检查更新**（启动时也会检查）会带进度圆环下载新 IPA，并通过 `apple-magnifier://install?url=…` 移交给 TrollStore 一键自动安装 —— 与 Dopamine 的机制相同。此功能**仅在 TrollStore 下可用**：普通 AltStore/SideStore 侧载版以个人证书签名，没有在设备上安装 IPA 的权限，因此会降级为打开发布页手动重新侧载。

### 启用 CarPlay（iOS）

CarPlay 的实现代码已完整存在于 `Sources/Kumone/Core/CarPlay/`，但**默认构建完全不包含 CarPlay**：既没有 `com.apple.developer.carplay-audio` entitlement，也没有 `UISupportsCarPlay` 和 CarPlay scene 声明。该 entitlement 需要先向 Apple 提交 CarPlay 音频应用[申请](https://developer.apple.com/contact/carplay/)并获批，未授权就打开会导致签名失败：

> Entitlement com.apple.developer.carplay-audio not found and could not be
> included in profile.

因此 CarPlay 改为一条命令按需开启：

```bash
make configure-carplay   # 开启
make configure           # 切回默认的无 CarPlay 构建
```

`make configure-carplay` 会基于 `Config/Info.plist` 与 `Config/KumoneIOS.entitlements` 派生出带 CarPlay 的副本放进 `ios/Config/Generated/`，再写一个 `ios/Config/CarPlay.local.xcconfig` 把构建指过去。这三个文件都不纳入 git，且**完全不改动 Xcode 工程文件** —— 开启 CarPlay 后 `git status` 依然干净，不会产生任何需要 review 的 diff。

拿到 Apple 授权后：

1. 在 [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list) 为你的 App ID 勾选 **CarPlay (Audio)** 能力。
2. 重新生成 provisioning profile 以携带新能力。
3. 执行 `make configure-carplay`。
4. `Cmd + Shift + K` 清理后在真机重新构建。

没有车也可以测试：Xcode ▸ Open Developer Tool ▸ Simulator，然后 I/O ▸ External Displays ▸ CarPlay。

## 构建

要求 macOS 15+、Xcode 26+。

```bash
swift build                    # 编译
Scripts/build-app.sh           # 打包 .app（输出 .build/app/Kumone.app）
Scripts/compile_and_run.sh     # 杀进程 → 重新打包 → 启动
```

## 架构

```
Sources/Kumone/
├── Core/
│   ├── API/            # NeteaseCrypto（weapi/eapi 加密）、NeteaseClient（传输 + Cookie）、NeteaseAPI（约 50 个端点）
│   ├── Models/         # 统一 Track 模型（兼容新旧两种 JSON 格式）、歌词解析器
│   ├── Player/         # PlayerService（队列 / 随机 / 循环 / FM / URL 解析）、UnblockService、NowPlayingManager
│   └── Storage/        # AccountStore、SettingsManager、两级图片缓存
├── DesignSystem/       # 设计 token、按钮样式（hover 缩放 / 行高亮 / chip）、骨架屏、卡片、跑马灯、封面取色
└── Features/           # 各页面 + 播放条 + 沉浸播放页 + 歌词/队列面板
```

不依赖任何第三方 API 服务器：weapi（AES-CBC 双层 + RSA）与 eapi（AES-ECB + MD5 摘要）加密为原生 Swift 实现，请求直达 `music.163.com` / `interface.music.163.com`。

## 相关项目

想要 **tvOS** 版本？欢迎使用我朋友 Svend 维护的 [Sonimbus](https://github.com/gee1k/sonimbus) —— 一个 Apple TV 上的网易云音乐客户端。

## Credits

Kumone 是从零编写的 Swift 实现，未复制以下项目的代码，但深度参考了它们的设计与实现思路，在此致谢：

- [YesPlayMusic](https://github.com/qier222/YesPlayMusic)（MIT，© qier222）— 功能设计、网易云 API 端点与行为逻辑的参考
- [kaset](https://github.com/sozercan/kaset)（MIT，© sozercan）— UI 设计系统、动效与 SwiftPM 打包方案的参考
- [UnblockNeteaseMusic/server](https://github.com/UnblockNeteaseMusic/server)（LGPL-3.0-only）— 灰色歌曲第三方音源的接口与匹配策略参考（`UnblockService.swift` 为独立的 Swift 重新实现）
- [LyricsX](https://github.com/ddddxxx/LyricsX)（MPL-2.0，© ddddxxx）— 桌面歌词窗口的设计参考（窗口配置、屏幕比例定位；`DesktopLyrics.swift` 为独立的 SwiftUI 实现）

## 协议与说明

本项目以 [LGPL-3.0-only](LICENSE) 协议开源（随附 [GPL-3.0](COPYING) 文本）。仅供学习交流，音乐数据与版权归网易云音乐及各音源平台所有。不支持下载、无社交功能。
