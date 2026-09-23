# Changelog

每个版本必须在此记录变更；发布流程会提取对应版本的段落，作为 GitHub Release
正文并渲染进 Sparkle appcast 的更新说明。段落格式：`## <版本号> - <日期>`，条目必须写成单行。

每个版本先写完整的**英文**部分（`### Added` / `### Fixed` / `### Improved`），再用一条
`---` 分隔，随后是完整的**中文**部分（`### 新增` / `### 修复` / `### 改进`）。英文块与中文块
的条目一一对应、顺序一致。（0.3.19 起采用此双语分块格式；更早的版本沿用旧的中英交替格式。）

## 0.3.20 - 2026-09-23

### Added

- **macOS** (experimental): AutoMix — an Apple-Music-style continuous-playback mode with beat-matched transitions, optional stem separation, loudness compensation and an output-device picker, on a new dual-deck AVAudioEngine backend. Off by default; turn it on in Settings. Thanks @XerWandeRer (#102).

---

### 新增

- **macOS**（实验性）：AutoMix——类 Apple Music 的连续播放模式,支持节拍对齐的过渡、可选的人声 / 伴奏分离、响度补偿与输出设备选择,基于全新的双 deck AVAudioEngine 后端。默认关闭,可在设置里开启。感谢 @XerWandeRer（#102）。

## 0.3.19 - 2026-09-23

### Added

- **iOS + macOS**: an optional on-disk song cache (on by default, 100–1000 MB) — recently played tracks play from local storage, so replays work offline and rapid track switching is smoother; adjust the size or clear it in Settings. Thanks @yamakze (#109, part of #106).
- **iOS + macOS**: per-source control for grey (unavailable) tracks — enable or disable each fallback audio source (酷狗 / 酷我 / …) in Settings, plus stricter title/artist/duration match validation so a wrong song is no longer substituted. Thanks @yamakze (#104, addresses #77).

### Fixed

- **macOS**: the Settings 「播放页模式」 picker now offers only the two layouts macOS actually renders (黑胶 / 经典) instead of four. (#105)
- **macOS**: the now-playing page slides in more smoothly — the titlebar and ambient tint fade out as the page rises, the arrow cursor no longer leaks from the sidebar divider onto the page, and the artwork cross-fades in. Thanks @sld272 (#100).
- **iOS**: tapping a track's cover in a list now plays it directly instead of opening the album, and the now-playing volume control moved into a compact popover. Thanks @yamakze (#108, part of #106).

---

### 新增

- **iOS + macOS**：可选的本地歌曲缓存(默认开启,100–1000 MB)——最近听过的歌从本地播放,断网也能重播、快速切歌更顺;可在设置里调整大小或清除。感谢 @yamakze（#109，#106 的一部分）。
- **iOS + macOS**：灰色(无版权)歌曲的音源可逐个开关——在设置里启用 / 禁用每个备用音源(酷狗 / 酷我 / …),并加入更严格的标题 / 歌手 / 时长匹配校验,不再匹配到错误的歌曲。感谢 @yamakze（#104，缓解 #77）。

### 修复

- **macOS**：设置里的「播放页模式」现在只提供 macOS 实际支持的两种(黑胶 / 经典),不再显示四种。（#105）
- **macOS**：进入播放页的动画更顺滑——标题栏与环境色随页面升起淡出,侧栏分隔条的箭头光标不再渗到播放页上,封面淡入。感谢 @sld272（#100）。
- **iOS**：列表里点击歌曲封面现在直接播放,而不是进入专辑,播放页音量改为紧凑的弹出条。感谢 @yamakze（#108，#106 的一部分）。

## 0.3.18 - 2026-09-16

### Added / 新增

- **iOS + macOS**: a sleep timer — stop playback after a set duration or at the end of the current track, from the 播放 menu (macOS) or the now-playing more-actions menu (iOS). Thanks @yamakze (#98, closes #96).
- **iOS + macOS**：新增睡眠定时——可在设定时长后、或当前歌曲播完后停止播放,入口在「播放」菜单(macOS)或播放页的更多菜单(iOS)。感谢 @yamakze（#98，关闭 #96）。
- **iOS + macOS**: jump from a playing track to its artist or album page (and play from there) via the artwork / track menu. Thanks @yamakze (#95, closes #80).
- **iOS + macOS**：可从正在播放的歌曲跳转到其歌手或专辑页并从那里播放(通过封面 / 歌曲菜单)。感谢 @yamakze（#95，关闭 #80）。
- **macOS**: an ambient background behind the main window derived from the current track's artwork — a soft color wash plus a subtle titlebar tint that follows the playing song. On by default; toggle it off or adjust the intensity in Settings. Thanks @yamakze (#86).
- **macOS**：主窗口新增取自当前封面的氛围背景——柔和的色彩铺底 + 淡淡的标题栏染色，随播放歌曲变化。默认开启,可在设置里关闭或调节强度。感谢 @yamakze（#86）。
- **iOS**: the artwork ambient background is now available on iOS too, with the same toggle + intensity slider in Settings. Thanks @yamakze (#99).
- **iOS**：封面氛围背景现在 iOS 也支持,设置里同样有开关与强度滑块。感谢 @yamakze（#99）。

### Fixed / 修复

- **macOS**: the now-playing artwork no longer snaps out of place during the open/close transition when the image finishes loading mid-animation. Thanks @Perfect9s (#92).
- **macOS**：进入 / 退出播放页时,封面即使在动画途中才加载完也不再错位跳动。感谢 @Perfect9s（#92）。
- **macOS**: the main-window titlebar ambient tint now matches the app's light/dark appearance instead of lagging a step behind it. Thanks @yamakze (#93).
- **macOS**：主窗口标题栏的氛围染色现在会正确匹配 App 的浅色 / 深色外观,不再慢一拍。感谢 @yamakze（#93）。
- **macOS**: switching a fixed theme (Light/Dark) back to "follow system" now updates the native titlebars of both the main and Settings windows immediately, via `NSApp.appearance`. (#94)
- **macOS**：把固定主题(浅色 / 深色)切回「跟随系统」时,主窗口与设置窗口的原生标题栏现在会通过 `NSApp.appearance` 立即同步。（#94）

- **macOS**: the toolbar search field and the floating player bar now keep more clearance from the window's rounded corners, so their capsules no longer nearly touch the window edges and the inner/outer corner radii stop visually merging. (#88)
- **macOS**：工具栏搜索框与悬浮播放条现在与窗口圆角保持更多间距,不再几乎贴住窗口边缘,内外圆角也不再互相干扰。（#88）
- **macOS**: the album artwork in the player bar and the immersive now-playing page no longer shows a stray blue focus ring (macOS 27 drew the system focus ring on those decorative artwork buttons). (#97)
- **macOS**：播放条与沉浸播放页的专辑封面不再出现多余的蓝色聚焦边框（macOS 27 会在这些装饰性封面按钮上绘制系统聚焦环）。（#97）

## 0.3.17 - 2026-09-10

### Added / 新增

- **macOS**: a 「减少推荐」 (reduce recommendation) right-click action on un-liked songs in 每日推荐 and 私人雷达 lists — it asks NetEase to swap the song out and replaces it in place. Thanks @yamakze (#84, closes #74).
- **macOS**：每日推荐 / 私人雷达 列表里,未收藏歌曲的右键菜单新增「减少推荐」——会请求网易云替换该歌曲并就地替换。感谢 @yamakze（#84，关闭 #74）。

### Fixed / 修复

- **iOS**: the lock screen and Dynamic Island Now Playing controls show previous/next track again instead of back-15s/forward-15s. Registering the ±15s skip commands (added for CarPlay in 0.3.15) made iOS pick the podcast-style skip layout system-wide and hid the track buttons; those commands are removed, so previous/next are the media buttons everywhere (CarPlay included). (#83, #87)
- **iOS**：锁屏与灵动岛的「正在播放」控制重新显示上一首 / 下一首，而不是后退 15 秒 / 前进 15 秒。此前为 CarPlay 注册的 ±15 秒快进快退命令（0.3.15 引入）让 iOS 在全局采用了播客式布局、把切歌按钮挤掉了；现已移除这两个命令，上一首 / 下一首恢复为各处（含 CarPlay）的系统媒体按钮。（#83、#87）
- **macOS**: the search results page no longer shows a second, empty system search box on top of the toolbar search field — the page's `.searchable` bar is now iOS-only. Thanks @yamakze (#90, closes #89).
- **macOS**：搜索结果页不再在工具栏搜索框之外多出一个空的系统搜索框——结果页的 `.searchable` 搜索栏改为仅 iOS 使用。感谢 @yamakze（#90，关闭 #89）。

## 0.3.16 - 2026-09-03

### Added / 新增

- **iOS**: CarPlay Now Playing gains a working Up Next button — tapping it pushes the live playback queue (current track pinned on top, up to 300 upcoming rows), and picking a row jumps straight to that track. Outside FM mode the button row also gains 随机 and 循环 controls whose icons track `shuffleEnabled` / `repeatMode`, and the album-artist button opens the current track's album (falling back to its first artist for cloud-disk tracks with no album). Thanks @MikeChongCan (#54).
- **iOS**：CarPlay Now Playing 的「播放队列」按钮现在可用——点击弹出实时播放队列（当前曲目置顶，最多 300 条待播），点任意一行直接跳转播放。非 FM 模式下按钮区新增 随机 / 循环 控件，图标跟随 `shuffleEnabled` 与 `repeatMode` 变化；专辑歌手按钮可跳转当前曲目的专辑（云盘歌曲等无专辑信息时回退到第一位歌手）。感谢 @MikeChongCan（#54）。
- **Build**: `make configure` / `make configure-carplay` select which capabilities the iOS build ships with, plus `make build` / `test` / `app` / `project` wrappers. Run `make` for the list. (#54)
- **Build**：新增 `make configure` / `make configure-carplay` 切换 iOS 构建包含的能力，另有 `make build` / `test` / `app` / `project` 等封装。执行 `make` 查看全部目标。（#54）

### Changed / 变更

- **iOS**: CarPlay is now excluded from the default build entirely, not just left unsigned — `UISupportsCarPlay` and the `CPTemplateApplicationSceneSessionRoleApplication` scene declaration have moved out of `ios/Config/Info.plist` and are injected, together with the `com.apple.developer.carplay-audio` entitlement, only by `make configure-carplay`. The overlay is written to untracked files and never touches the Xcode project, so enabling CarPlay leaves the working tree clean. Replaces the previous "uncomment `KumoneIOS.entitlements.example` by hand" flow. (#54)
- **iOS**：CarPlay 现在从默认构建中完全移除，而不只是不签名——`UISupportsCarPlay` 与 `CPTemplateApplicationSceneSessionRoleApplication` scene 声明已移出 `ios/Config/Info.plist`，与 `com.apple.developer.carplay-audio` entitlement 一起，仅由 `make configure-carplay` 注入。覆盖文件均不纳入 git 且完全不改动 Xcode 工程，开启 CarPlay 后工作区依然干净。取代原先手动取消注释 `KumoneIOS.entitlements.example` 的流程。（#54）

### Fixed / 修复

- **iOS**: the in-app updater now saves the downloaded IPA into the app's Documents folder — findable in the Files app under On My iPhone ▸ Kumone (the app now enables file sharing) — and opens a share sheet so it can be saved or handed straight to a signing tool (全能签 / ESign / AltStore …), instead of only offering an export dialog that left users unable to locate the file. (#73, #50)
- **iOS**：应用内更新现在会把下载的 IPA 保存到 App 的 Documents 目录——可在「文件」App ▸ 我的 iPhone ▸ Kumone 里找到（已开启文件共享）——并弹出分享面板，可保存或直接导入签名工具（全能签 / ESign / AltStore 等），不再是之前那种让人找不到文件的导出弹窗。（#73，#50）

## 0.3.15 - 2026-09-03

### Added / 新增

- **iOS**: CarPlay support — strict 4-tab mirror of the App's main UI (推荐 / 精选 / 漫游 / 我的): 推荐 tab exposes 每日推荐 / 推荐歌单 / 雷达歌单 / 排行榜 / 新碟上架 / 推荐歌手; 精选 tab exposes 精品 / 热门 / 排行榜 / 官方 / 华语; 漫游 tab is a single start/skip row; 我的 tab exposes 我的音乐 (with 每日推荐 / 最近播放 / 音乐云盘 / 我喜欢的音乐) + 创建的歌单 + 收藏的歌单. Now Playing gains a 喜欢 button (always on) and a 不喜欢 / trash button (FM mode only, matching the App's FMView); ±15s skip, shuffle, and repeat commands also route through CarPlay's Now Playing buttons. CarPlay is opt-in and off by default (the audio entitlement stays commented until Apple approval). Thanks @zlfyuan (#69).
- **iOS**：新增 CarPlay 支持——严格对齐 App 主界面的 4 个 Tab（推荐 / 精选 / 漫游 / 我的）：推荐 tab 含 每日推荐 / 推荐歌单 / 雷达歌单 / 排行榜 / 新碟上架 / 推荐歌手；精选 tab 含 精品 / 热门 / 排行榜 / 官方 / 华语；漫游 tab 单按钮开始/换一首；我的 tab 含 我的音乐（含每日推荐 / 最近播放 / 音乐云盘 / 我喜欢的音乐）+ 创建的歌单 + 收藏的歌单。Now Playing 新增 喜欢按钮（始终可用）和 trash / 不喜欢按钮（仅在 FM 模式显示，对齐 App FMView）；±15秒快进快退、随机、循环按钮均已接通。CarPlay 默认关闭、需手动启用（音频授权在获批前保持注释）。感谢 @zlfyuan（#69）。

### Fixed / 修复

- **iOS**: CarPlay 漫游 tab now reflects the live playback state — a "正在漫游" row surfaces the currently playing track while FM is on, the action button toggles 换一首 / 继续漫游 with the actual isPlaying value, and the tab no longer restarts FM when paused. The CarPlay connector now subscribes to both `$isFMMode` and `$isPlaying` so the FM template refreshes whenever playback state changes.
- **iOS**：CarPlay 漫游 tab 现在会同步播放状态：FM 模式下显示"正在漫游"行（当前曲目），操作按钮随 `isPlaying` 在"换一首 / 继续漫游"之间切换，FM 暂停时点击按钮是继续而不是重启 FM。CarPlay 连接器同时订阅 `$isFMMode` 和 `$isPlaying`，播放状态变化时刷新 FM 模板。
- **iOS**: the `com.apple.developer.carplay-audio` entitlement is now left commented in `ios/Config/KumoneIOS.entitlements` by default, and a ready-to-copy template is added at `ios/Config/KumoneIOS.entitlements.example`. CarPlay activation requires the [Apple CarPlay audio capability](https://developer.apple.com/contact/carplay/) which most developer accounts are not granted; leaving the entitlement on without approval breaks real-device builds with `Entitlement ... not found and could not be included in profile`. CarPlay code and Info.plist scene configuration remain in place — once Apple approval lands, just uncomment and re-sign. README updated with the enable steps.
- **iOS**：`com.apple.developer.carplay-audio` 在 `ios/Config/KumoneIOS.entitlements` 中默认改为注释状态，并新增模板文件 `ios/Config/KumoneIOS.entitlements.example`。CarPlay 激活需要 [Apple CarPlay 音频能力](https://developer.apple.com/contact/carplay/)，多数开发者账号不会被授予；未授权时打开会导致真机签名失败（`Entitlement ... not found and could not be included in profile`）。CarPlay 实现代码与 Info.plist scene 配置保持不变——拿到 Apple 授权后取消注释重新签名即可。README 同步更新启用步骤。
- **iOS**: fixed the app launching in letterboxed compatibility mode (black bars, oversized UI) on some devices such as iPhone 15 Pro Max — the launch screen was emitted as a malformed nested `UILaunchScreen`; it is now declared flat and correctly, so the app renders at native full-screen resolution. (#71)
- **iOS**：修复部分设备（如 iPhone 15 Pro Max）以信箱模式（黑边、界面放大）启动的问题——此前 `UILaunchScreen` 被生成为嵌套的错误结构，现改为正确的扁平声明，应用按原生全屏分辨率渲染。（#71）
- **iOS**: playlist cover cards on 推荐 / 精选 no longer misalign vertically when titles wrap to two lines — the play-count badge and hover button are now overlays that don't affect the cover's layout size. Thanks @sld272 (#68).
- **iOS**：推荐 / 精选 的歌单封面卡片在标题换行时不再上下错位——播放量徽标与悬浮按钮改为不参与封面尺寸计算的 overlay。感谢 @sld272（#68）。
- **iPadOS**: Settings and Search are now reachable on iPad — gear + magnifier entries in the sidebar footer. The iPad layout previously had no Settings entry (so audio quality etc. couldn't be changed) and no working search. (#67, #59)
- **iPadOS**：iPad 现在可以打开设置和搜索——侧栏底部新增齿轮与放大镜入口。此前 iPad 布局没有设置入口（音质等无法切换）、也没有可用的搜索。（#67，#59）
- **iPadOS**: the landscape now-playing page no longer stretches its two columns edge-to-edge (cramped on the left, a wide blank gutter on the right) — the content band is capped and centred. (#62)
- **iPadOS**：横屏播放页不再把两栏铺满整个宽度（左侧拥挤、右侧大片留白）——内容区域现在限制最大宽度并居中。（#62）
- **macOS**: closing the main window (Cmd+W / red button) now hides it instead of destroying the scene, so the Dock icon always brings it back; also covers reopening after minimize and fronting the window when it is hidden behind others. Regression from the #52 single-window change. (#60, #63, #66, #70)
- **macOS**：用 Cmd+W / 红灯关闭主窗口时改为隐藏而非销毁场景，点击 Dock 图标始终能重新唤出；同时覆盖最小化后重开、以及窗口被其他窗口盖住时的前置。此为 #52 单窗口改动引入的回归。（#60、#63、#66、#70）

### Improved / 改进

- **iOS**: in the immersive now-playing page, tapping the small top-left cover while lyrics (or the queue) are shown collapses back to the full artwork — matching Apple Music. (#50)
- **iOS**：沉浸播放页在显示歌词（或队列）时，点击左上角的小封面即可收起、回到大封面视图，与 Apple Music 一致。（#50）
- **iOS**: detail-page loading skeletons unified, the FM (漫游) page scales responsively on small/landscape screens, immersive-lyrics scroll & scale are smoother, and floating player-bar / tab-bar clearance is computed more accurately. Thanks @fanyuexiang (#65).
- **iOS**：详情页加载骨架统一、FM（漫游）页在小屏/横屏自适应缩放、沉浸歌词滚动与缩放更顺滑、底部播放条 / tab bar 留白计算更准确。感谢 @fanyuexiang（#65）。

## 0.3.14 - 2026-08-29

### Added / 新增

- **iOS + macOS**: a retro vinyl record-player now-playing mode (黑胶模式) — programmatic vinyl + tonearm with swipe-to-switch. Opt in from Settings (the default stays 沉浸模式). Thanks @MikeChongCan (#55).
- **iOS + macOS**：新增黑胶唱片播放页模式（黑胶模式）——矢量唱片 + 唱臂，可滑动切换。默认仍是沉浸模式，可在设置中选择。感谢 @MikeChongCan（#55）。
- **macOS**: a "桌面歌词水平居中" toggle that locks the floating lyric capsule to the horizontal centre of the screen (vertical drag still works). (#48)
- **macOS**：新增「桌面歌词水平居中」开关，可把悬浮歌词锁定在屏幕水平中央（仍可上下拖动）。（#48）

### Fixed / 修复

- **macOS**: the desktop-lyrics button in the player bar now reflects its on/off state — it read the setting directly and never re-rendered when toggled. (#48)
- **macOS**：播放条上的桌面歌词按钮现在会正确反映开/关状态——之前直接读取设置、切换后不重绘，颜色卡住。（#48）

## 0.3.13 - 2026-08-29

### Added / 新增

- **iOS + macOS**: furigana (振假名) shown over the kanji in Japanese lyrics, composing with the karaoke wipe; romaji sokuon and some dictionary readings corrected; a 3-way 歌词注音 setting (无 / 罗马音 / 振假名). Desktop lyrics now show the annotation too (closes #45). Thanks @xyspg (#53, follow-up on #25).
- **iOS + macOS**：日文歌词汉字上方显示振假名（与逐字高亮叠加）；修正罗马音促音与部分词典读音；歌词注音改为三档设置（无 / 罗马音 / 振假名）；桌面歌词也会显示注音（修复 #45）。感谢 @xyspg（#53，#25 的后续）。

### Fixed / 修复

- **macOS**: the app launches a single main window instead of two overlapping ones, and reopens correctly from the Dock — the scene is now a single-instance `Window`. Thanks @baisensenseng (#52, fixes #58).
- **macOS**：应用启动只创建单个主窗口（不再出现两个重叠窗口），并能正确从 Dock 重开——场景改为单实例 `Window`。感谢 @baisensenseng（#52，修复 #58）。
- **iOS**: the mini-player cover no longer reloads/flashes each time you switch tabs — `CachedAsyncImage` seeds from the in-memory cache synchronously. (#46)
- **iOS**：切换 TabBar 时底部播放栏封面不再重新加载/闪烁——图片会同步从内存缓存取用。（#46）
- **iOS**: the now-playing zoom transition anchors on the mini player again instead of the screen centre (a regression from the #35 idle-platter fix). (#57)
- **iOS**：进入/退出播放页的 zoom 转场重新以迷你播放器为锚点（此前退化为屏幕中央，是 #35 修复引入的回归）。（#57）

### Improved / 改进

- **iOS**: the 精选 / 搜索 / 收藏 card lists now show two columns on iPhone (like 推荐), instead of one. (#47)
- **iOS**：精选 / 搜索 / 收藏 的卡片列表在 iPhone 上改为两列显示（与推荐一致），不再是单列。（#47）

## 0.3.12 - 2026-08-27

### Improved / 改进

- **iOS + macOS**: stronger contrast for karaoke (逐字) lyrics — unsung characters are dimmer, so the word-by-word highlight is more obvious. Only songs that have NetEase verbatim (`yrc`) lyrics show it; others keep line-level highlighting.
- **iOS + macOS**：逐字歌词（卡拉OK）对比度加强——未唱的字更暗，逐字高亮更明显。仅对有网易云逐字歌词（`yrc`）的歌曲生效，其余保持整行高亮。

## 0.3.11 - 2026-08-27

### Added / 新增

- Karaoke (word-by-word) lyrics: when a song has NetEase verbatim (`yrc`) lyrics, the active line highlights character by character — sung characters bright, the current one fading in, the rest dim — synced live to playback. Songs without verbatim lyrics keep line-level highlighting. New setting 逐字歌词（卡拉OK）, on by default.
- 逐字歌词（卡拉OK）：当歌曲有网易云的逐字歌词（`yrc`）时，当前行会逐字高亮——已唱的字亮、正在唱的字渐亮、未唱的字暗——实时跟随播放。没有逐字歌词的歌曲保持整行高亮。设置新增「逐字歌词（卡拉OK）」，默认开启。

### Fixed / 修复

- iOS: turning off "启动时自动检查更新" now actually stops the launch update sheet — the 0.3.9 toggle's iOS gate had silently not been applied. (#42)
- iOS：关闭「启动时自动检查更新」现在真的会停掉启动时的更新弹窗——0.3.9 那个开关的 iOS 侧判断此前未生效。（#42）

## 0.3.10 - 2026-08-27

### Added / 新增

- iOS: an opt-in concise now-playing mode (简洁模式) alongside classic and immersive — focused artwork/lyrics/controls, tap-to-switch, draggable lyrics with seek, a half-screen queue, and an AirPlay entry. Default is unchanged (immersive). Thanks @AL-Pinecore (#41).
- iOS：新增可选的「简洁模式」播放页（与经典/沉浸并列）——聚焦的封面/歌词/控制、点击切换、可拖动歌词并跳转、半屏队列、AirPlay 入口。默认仍是沉浸模式。感谢 @AL-Pinecore（#41）。
- The four playing-indicator bars are now driven by the real audio spectrum (via MTAudioProcessingTap, with per-band adaptive windows); sources without a tappable stream keep the previous sine-wave animation. Thanks @XerWandeRer (#39, revisits #14).
- 「正在播放」那一行的四根柱子现在由真实音频频谱驱动（MTAudioProcessingTap，每频段自适应窗口）；无法挂载 tap 的音源保持原有的正弦波动画。感谢 @XerWandeRer（#39，重启 #14）。

### Fixed / 修复

- iOS 26: an empty translucent block no longer appears above the tab bar when nothing is playing — the mini-player accessory was always attached; it is now attached only when there is a current track. (#35)
- iOS 26：无歌曲播放时，Tab Bar 上方不再出现一个空的半透明块——迷你播放器的系统配件此前一直挂载，现在仅在有当前歌曲时才挂载。（#35）

## 0.3.9 - 2026-08-27

### Added / 新增

- Settings → 更新: a "启动时自动检查更新" toggle. Off suppresses the launch update sheet on iOS and disables Sparkle's scheduled checks on macOS; manual check still works. (#42)
- 设置 → 更新：新增「启动时自动检查更新」开关。关闭后 iOS 启动不再自动弹更新提示、macOS 停用 Sparkle 定时检查；仍可手动检查。（#42）

### Fixed / 修复

- macOS: clicking the Dock icon reopens the main window after it was closed (e.g. while desktop lyrics keeps the app running). Thanks @kitiho (#34, fixes #30).
- macOS：主窗口关闭后（例如桌面歌词让 App 常驻时）点击 Dock 图标可重新打开主窗口。感谢 @kitiho（#34，修复 #30）。
- iOS #31: the bottom mini-player text no longer turns white/unreadable after entering search — the accessory's colour scheme is pinned to the app appearance.
- iOS #31：进入搜索后底部迷你播放条文字不再变白看不清——已把该控件的配色方案固定为 App 外观。
- iOS #37: the volume slider in the now-playing page works again — a nested GeometryReader was silently swallowing the drag.
- iOS #37：播放页的音量滑轨恢复可用——此前一个嵌套的 GeometryReader 把拖动吞掉了。
- 最近播放（最近一周）now records plays: the client was sending only the `play` weblog and never the `startplay` one that writes the recent-plays list. Thanks @fanyuexiang for the root cause (#33).
- 最近播放（最近一周）现在能记录了：客户端此前只发了 `play` 打卡、从未发写入「最近播放」列表的 `startplay`。感谢 @fanyuexiang 的根因分析（#33）。
- Gray-track unblock tries 酷狗 before 酷我 — 酷我 increasingly returns a "请在酷我音乐APP播放" promo clip instead of the song, so it is now the last resort. (#44)
- 灰色歌曲解锁改为先试酷狗再试酷我——酷我越来越多返回「请在酷我音乐APP播放」的提示音而非歌曲，现降为最后备选。（#44）

### Improved / 改进

- Performance: an idle, loaded home page no longer burns ~16% CPU. MarqueeText now animates a render-server CATextLayer instead of a forever SwiftUI animation; the active lyric line is computed once and published only on change; shelves use LazyHStack. Thanks @XerWandeRer (#38).
- 性能：静止的首页不再持续占用约 16% CPU。跑马灯改为在 render server 侧的 CATextLayer 上做动画（不再是永不停止的 SwiftUI 动画）；当前歌词行集中计算、仅在换行时广播；货架改用 LazyHStack。感谢 @XerWandeRer（#38）。
- iOS: best-effort now-playing hardening (declare the media session as audio) for the "can't tap back into the app from the system Now Playing / Dynamic Island" reports, which otherwise look like an iOS 26/27-beta issue. (#36, #40)
- iOS：对「无法从系统正在播放 / 灵动岛点回 App」的问题做了尽力而为的加固（声明媒体会话为音频）；该问题很可能是 iOS 26/27 beta 的系统问题。（#36、#40）
- CI: releases can auto-bump the Homebrew cask (guarded so a missing token can't fail a release). Thanks @Goooler (#43).
- CI：发布可自动提交 Homebrew cask 版本更新（已加保护，缺 token 也不会让发布失败）。感谢 @Goooler（#43）。

## 0.3.8 - 2026-08-25

### Fixed / 修复

- macOS / iPad: after opening a card from the Home page (每日推荐, a playlist, album or artist), the sidebar looked stuck — tapping another section did nothing until you pressed Back. Those cards used closure-based `NavigationLink`s, whose pushes live in the stack's internal state rather than the bound `NavigationPath`, so the sidebar's path reset couldn't pop them (and an `.id()` reset does not work inside `NavigationSplitView` — verified on device). The Home cards now use value-based navigation, which the existing sidebar-switch reset clears correctly. (#29)
- macOS / iPad：从推荐页打开卡片（每日推荐、歌单、专辑、歌手）后，侧边栏看起来卡住——点其他分区没反应，必须先点返回。这些卡片用的是闭包式 `NavigationLink`，其压栈存在于导航栈内部状态、而非绑定的 `NavigationPath`，所以侧边栏的 path 重置弹不掉它们（而 `.id()` 重置在 `NavigationSplitView` 里无效——已在真机验证）。推荐页卡片改为值驱动导航，配合现有的侧边栏切换重置即可正确清空。（#29）

## 0.3.7 - 2026-08-25

### Fixed / 修复

- iOS 16/17: tapping the mini player did nothing — the full-screen Now Playing page never appeared. The pre-iOS-18 presentation matched the page's geometry to the mini player bar (`matchedGeometryEffect(.frame, isSource: false)`), which shrank the whole page to bar size. It now presents full-screen with a bottom slide-up (matching the pull-down-to-dismiss); iOS 18+ keeps its zoom transition. (#28, regression from #27)
- iOS 16/17：点击迷你播放条没有任何反应——全屏播放页始终弹不出来。iOS 18 以下的呈现用 `matchedGeometryEffect(.frame, isSource: false)` 把播放页的尺寸匹配到了迷你播放条，导致整页被压缩成播放条大小。现在改为全屏呈现 + 底部上滑动画（与下拉关闭方向一致）；iOS 18+ 仍保留 zoom 转场。（#28，#27 引入的回归）

## 0.3.6 - 2026-08-25

### Added / 新增

- iOS: immersive iPhone Now Playing — compact track header, synced lyrics, artwork and queue, with pull-to-dismiss and a spatial transition from the mini player (zoom on iOS 18+, matched-geometry below). A new Settings → Appearance toggle switches between the immersive and classic layouts (immersive by default). macOS is unchanged. Thanks @miloquinn (#27).
- iOS：iPhone 沉浸式播放页——紧凑信息栏、同步歌词、封面与播放队列，支持下拉关闭以及从迷你播放器进入的空间转场（iOS 18+ 用 zoom，更低版本用 matched-geometry）。设置 → 外观新增开关可在沉浸式与经典布局间切换（默认沉浸式）。macOS 不变。感谢 @miloquinn（#27）。
- iOS 26: a Liquid Glass mini player rendered as the system `tabViewBottomAccessory` — it collapses into an inline layout together with the tab bar when the list scrolls down; iOS 16–25 keep the existing custom glass bar. Thanks @miloquinn (#27).
- iOS 26：迷你播放器改用系统 `tabViewBottomAccessory` 的液态玻璃样式——列表下滑时随 Tab Bar 收纳为行内样式；iOS 16–25 继续使用现有的自定义玻璃条。感谢 @miloquinn（#27）。

### Improved / 改进

- iOS: refined the compact track list — larger artwork and row height, clearer title/artist/duration hierarchy, track numbers hidden in compact layouts, and playback state shown over the artwork; Dynamic Type preserved. Thanks @miloquinn (#27).
- iOS：精修紧凑歌曲列表——更大的封面与行高、更清晰的标题/歌手/时长层级、紧凑布局隐藏序号、封面上显示播放状态；保留动态字体适配。感谢 @miloquinn（#27）。

## 0.3.5 - 2026-08-25

### Added / 新增

- Dock menu (right-click the Dock icon): play/pause, next, previous, shuffle, a repeat submenu, and the last six places playback started from — playlists, albums, artists, daily recommendations, cloud disk, the play-record list, heartbeat mode and personal FM. Picking one reloads it and plays; heartbeat mode and personal FM are regenerated rather than resumed, since neither is a fixed list. Thanks @XerWandeRer (#24).
- Dock 菜单（右键 Dock 图标）：播放/暂停、下一首、上一首、随机播放、循环模式子菜单，以及最近播放过的 6 个来源——歌单、专辑、歌手、每日推荐、音乐云盘、最近播放、心动模式、私人漫游。点击即重新载入并播放；心动模式与私人漫游会重新生成而非恢复原队列，因为它们本就不是固定歌单。感谢 @XerWandeRer（#24）。
- Romaji above Japanese lyrics (romaji / original / translation) on the full-screen now-playing lyrics and the side lyrics panel. Netease's hand-checked `romalrc` is used when present, otherwise an offline system transcription fills the gaps; Japanese-only, off by default (Settings → Appearance). Thanks @XerWandeRer (#25).
- 日文歌词上方显示罗马音（罗马音 / 原文 / 翻译），覆盖全屏播放页大歌词与右侧歌词面板。有网易云人工校对的 `romalrc` 时优先使用，缺失时用系统离线转写兜底；仅日文歌触发，默认关闭（设置 → 外观）。感谢 @XerWandeRer（#25）。

### Fixed / 修复

- macOS: the window no longer grows by the sidebar's width every time the immersive now-playing page is dismissed. The window minimum was a SwiftUI content constraint, so while the now-playing page collapsed the sidebar the whole 1020pt minimum landed on the detail column; restoring the sidebar then forced the window to 1248pt. The minimum is now reduced by the sidebar width while it is collapsed. Thanks @XerWandeRer (#23, the real fix for #19).
- macOS：退出沉浸式播放页时窗口不再每次都变宽一个侧边栏的宽度。窗口最小宽度原本是 SwiftUI 内容约束，播放页折叠侧边栏时 1020pt 下限全落在详情列上，恢复侧边栏后被撑到 1248pt；现在折叠期间会减去侧边栏宽度。感谢 @XerWandeRer（#23，真正修复 #19）。
- macOS: the immersive now-playing page no longer leaves a toolbar's worth of empty space at the top — the toolbar is hidden there but SwiftUI kept reserving its safe area, pushing the close button ~68pt down. The button insets are also even now (20pt both edges). Thanks @XerWandeRer (#24).
- macOS：沉浸式播放页顶部不再多出一个工具栏高度的空白——该页隐藏了工具栏，但 SwiftUI 仍为其保留安全区域，把收起按钮推到距顶部约 68pt；按钮四边间距也统一为 20pt。感谢 @XerWandeRer（#24）。

## 0.3.4 - 2026-08-25

### Fixed / 修复

- Now Playing screen was misaligned on iPhone whenever a track was playing — content and the top-right lyrics button spilled off the right edge. The transport-control row was a fixed-width `HStack`; with the like button present it summed to ~430pt, wider than any iPhone, so it overflowed and stretched the whole layout (and its corner overlays) past the screen edge. Controls now lay out in equal-width slots that fit any device, and the page is pinned to the screen width. (#22)
- 播放界面在有歌曲播放时于 iPhone 上错位——内容和右上角歌词按钮溢出到屏幕右侧之外。底部控制条原本是固定宽度的 `HStack`，加上「喜欢」按钮后总宽约 430pt、比任何 iPhone 都宽，于是溢出并把整个布局（含四角浮层）撑到屏幕之外。现在控制按钮按等宽均分排布，可适配任意机型，并将页面钉定到屏幕宽度。（#22）

## 0.3.3 - 2026-08-25

### Improved / 改进

- iOS 16–25 glass tab bar rebuilt to match Telegram's Liquid Glass bar 1:1 (studied from telegram-ios `TabBarComponent` / `LiquidLensView`): the selection is a bar-height capsule using Telegram's own faint tint — a subtle darkening in light, a subtle lightening in dark — instead of a bright chip, and unselected items use an 80%-black filled icon + 10pt label. The pill is now **interactive**: drag it and it tracks your finger, switching tabs live and settling with a spring on release; a tap slides it there.
- iOS 16–25 玻璃 Tab Bar 按 Telegram 的 Liquid Glass 栏 1:1 重制（参照 telegram-ios 的 `TabBarComponent` / `LiquidLensView`）：选中块改为与栏等高的胶囊、采用 Telegram 同款的淡淡着色（浅色下轻微压暗、深色下轻微提亮），不再是过亮的方块；未选中项用 80% 黑的填充图标 + 10pt 文字。选中滑块现在**可交互**：拖动它会跟随手指在标签间滑动、实时切换页面，松手后以弹簧动画归位；点按则滑动过去。

## 0.3.2 - 2026-08-25

### Fixed / 修复

- iOS in-app update no longer tries to "detect" TrollStore. The previous detection (via `canOpenURL` / `LSApplicationProxy`) gave false negatives — reporting "TrollStore not detected" on devices that clearly had it and had URL schemes enabled. Following Dopamine, the update sheet now always offers a one-tap **自动安装（TrollStore）** that fires `apple-magnifier://install?url=…` directly (`open` needs no scheme whitelisting), with a manual **下载 IPA** fallback for other sideloaders.
- iOS 应用内更新不再「检测」TrollStore。之前用 `canOpenURL` / `LSApplicationProxy` 检测会误判——明明装了巨魔、也开了 URL Scheme，却提示「未检测到 TrollStore」。参照 Dopamine，更新弹窗现在始终提供一键 **自动安装（TrollStore）**，直接唤起 `apple-magnifier://install?url=…`（`open` 无需 scheme 白名单），并保留 **下载 IPA** 手动侧载入口。

### Improved / 改进

- iOS 16–25 glass tab bar now matches the iOS 26 native Liquid Glass bar 1:1: a near-full-width frosted capsule, filled primary-colour icons (accent on the selected tab), and a subtle sliding lighter-glass pill — replacing the earlier bright, oversized chip and washed-out grey icons.
- iOS 16–25 玻璃 Tab Bar 现在与 iOS 26 原生 Liquid Glass 栏 1:1 对齐：接近满宽的磨砂胶囊、填充的主色图标（选中项为强调色）、低调滑动的浅玻璃选中块——取代之前过亮过大的方块与灰扁的图标。

## 0.3.1 - 2026-08-25

### Fixed / 修复

- iOS 16–25: removed the duplicate system tab bar that was showing behind the glass tab bar. The pre-26 layout no longer hosts a `TabView` (each tab is a persistent `NavigationStack` shown/hidden in place), so there is now exactly one tab bar.
- iOS 16–25：修复玻璃 Tab Bar 背后还叠着一个系统原生 Tab Bar 的问题。26 以下的布局不再使用 `TabView`（每个标签为常驻的 `NavigationStack`，就地显隐），现在只有一个 Tab Bar。

### Improved / 改进

- iOS 16–25 glass tab bar: the selected tab now sits on a brighter, dimensional glass chip — a Telegram-style continuous-rounded squircle with a specular highlight, hairline rim, and soft shadow — that clearly lifts off the bar, instead of the previous flat wash.
- iOS 16–25 玻璃 Tab Bar：选中项改为更明亮、有立体感的玻璃方块——Telegram 风格的连续圆角方块，带高光、细描边与柔和投影——明显浮于栏面，不再是之前扁平的一层。

## 0.2.8 - 2026-08-25

### Added / 新增

- AirPlay: the now-playing page (and the macOS player bar) gain a system route picker for sending audio to AirPlay / Bluetooth devices; playback is audio-only, so it routes sound instead of mirroring the screen (#20)
- AirPlay：播放页（及 macOS 播放条）新增系统输出设备选择器，可将音频投送到 AirPlay / 蓝牙设备；由于是纯音频播放，只路由声音而非镜像屏幕（#20）

## 0.3.0 - 2026-08-25

### Added / 新增

- iOS 16 support: the minimum iOS version is lowered from 17 to 16 (iPhone 8 / X and later). The Observation-based state layer was rewritten to classic `ObservableObject`, with the high-frequency playback position split into its own `PlaybackClock` so only the scrubbers and lyrics re-render per tick — everything else is unaffected. macOS behavior is unchanged.
- Liquid Glass tab bar on iOS: iOS 26+ uses the native glass tab bar; iOS 16–25 gets a Telegram-style simulated glass bar (blurred material capsule with an edge highlight, hairline rim, and soft shadow).
- iOS 16 支持：最低 iOS 版本从 17 降到 16（iPhone 8 / X 及之后机型）。基于 Observation 的状态层重写为经典 `ObservableObject`，并把高频播放进度拆到独立的 `PlaybackClock`，每秒跳动只重绘进度条与歌词，其余视图不受影响；macOS 行为不变。
- iOS 玻璃 Tab Bar：iOS 26+ 使用系统原生玻璃 Tab Bar；iOS 16–25 使用 Telegram 风格的仿制玻璃（材质模糊胶囊 + 边缘高光 + 细描边 + 柔和投影）。

### Improved / 改进

- Redesigned the phone-code login form (rounded card-style input rows) and added a notice that SMS login may be blocked by NetEase's risk control — QR sign-in is recommended.
- 重新设计手机验证码登录表单（圆角卡片式输入行），并提示短信登录可能被网易云风控拦截、推荐使用扫码登录。

## 0.2.7 - 2026-08-25

### Added / 新增

- iOS in-app auto-update for TrollStore devices (Dopamine-style): checks GitHub on launch and from Settings → About → Check for Updates, shows a circular download-progress ring, and hands the IPA to TrollStore via `apple-magnifier://install?url=` for one-tap install; plain sideloads fall back to opening the release page (README documents the TrollStore requirement)
- iOS 应用内自动更新（针对 TrollStore / 巨魔设备，参考 Dopamine）：启动时与「设置 → 关于 → 检查更新」查询 GitHub，带圆环下载进度，并通过 `apple-magnifier://install?url=` 移交 TrollStore 一键安装；普通侧载则降级为打开发布页（README 已注明仅限 TrollStore）

## 0.2.6 - 2026-08-25

### Fixed / 修复

- SMS login called endpoints that do not exist (`/sms/sendcode`, `/login/cellphone`); now uses the real ones from upstream — `/api/sms/captcha/sent` and `/api/w/login/cellphone` — with the required fields
- iOS: opening an album/artist from Collections misrouted (went back to Collections, showed the target only after going back) — library navigation is now fully value-based (#13)
- Gray-track unblocking was fully broken on iOS: the App Transport Security cleartext exception was set via a nonexistent build setting and never shipped, so the HTTP third-party sources were blocked; ATS now ships correctly and Kuwo/Kugou use HTTPS where possible (#15)
- The now-playing page merged shuffle and repeat into one button, making it impossible to turn shuffle on; they are now separate controls (#18)
- macOS: Home/Explore content no longer widens after closing the now-playing page (#19, contributed by @baisensenseng)
- 短信登录调用了不存在的接口（`/sms/sendcode`、`/login/cellphone`）；现改为上游实际使用的 `/api/sms/captcha/sent` 与 `/api/w/login/cellphone`，并带上必需字段
- iOS：从「我的收藏」点开专辑/歌手会路由错乱（先回到收藏页、返回后才显示目标）—— 音乐库导航现已全部改为值式路由（#13）
- iOS 灰色歌曲解锁完全失效：App Transport Security 明文例外被写成了不存在的构建设置、从未生效，导致 HTTP 第三方音源被拦；现 ATS 正确打包，酷我 / 酷狗尽量走 HTTPS（#15）
- 播放页把随机和循环合并成了一个按钮，导致无法开启随机播放；现拆为两个独立控制（#18）
- macOS：关闭播放页后首页/精选内容不再变宽（#19，由 @baisensenseng 贡献）

## 0.2.5 - 2026-08-23

### Added / 新增

- Phone number + SMS code login, alongside QR (single-device iOS users no longer need a second phone) (#10)
- QR login survives app switching: polling tolerates background network errors and resumes when you return — screenshot the QR, scan it from your photo library in the NetEase app, come back (#10)
- iOS: Settings → About → Check for Updates looks up the latest GitHub release and links to it; README documents sideload install and update (#9)
- 手机号 + 短信验证码登录，与扫码并列（iOS 单设备用户不再需要第二台手机）（#10）
- 扫码登录支持切换 App：轮询容忍后台断网并在回到前台时续上 —— 截图二维码、去网易云 App 相册识别、再回来即可（#10）
- iOS：设置 → 关于 → 检查更新 会查询 GitHub 最新版本并给出下载链接；README 补充侧载安装与更新说明（#9）

### Fixed / 修复

- The last song of a list (e.g. Daily Recommendations) could be hidden behind the player bar; pages now reserve the clearance explicitly instead of relying on safe-area padding, which was unreliable inside navigation stacks (#12)
- Hovering the feature cards / shelf cards on Home no longer clips the enlarged card at the top and bottom (#11)
- 列表最后一首（如每日推荐）可能被播放条遮住的问题；页面改为显式预留净空，不再依赖导航栈内不可靠的安全区内边距（#12）
- 首页功能卡片 / 货架卡片 hover 放大时上下不再被裁切（#11）

## 0.2.4 - 2026-08-23

### Improved / 改进

- The iOS deployment target is lowered from 18.0 to 17.0 (iPhone XS and later); iOS 18-only APIs now have iOS 17 fallbacks. iOS 16 is not feasible — the app's state layer is built on the Observation framework, which requires iOS 17
- iOS 最低系统要求从 18.0 降至 17.0（iPhone XS 及之后机型均可安装）；iOS 18 专属 API 已补 iOS 17 回退。iOS 16 不可行 —— 应用状态层基于 Observation 框架，其最低要求即 iOS 17

## 0.2.3 - 2026-08-22

### Fixed / 修复

- iOS playback now resumes automatically after audio interruptions (phone calls, WeChat voice messages) end; playback also pauses when headphones are unplugged
- The artwork was clipped in iPhone landscape on the now-playing page; it now scales to the display height
- Lock-screen artwork is now served at 1024px so the tap-to-fullscreen presentation engages
- iOS 音频被打断（来电、微信语音等）结束后现在会自动恢复播放；拔出耳机时自动暂停
- iPhone 横屏下播放页封面显示不全的问题；封面现随屏幕高度自适应缩放
- 锁屏封面改为 1024px 高清图，点按全屏展示可正常触发

### Added / 新增

- The compact now-playing page fills the gap between the artwork and the controls with three auto-scrolling synced lyric lines; tap them (or the top-right button) for the full lyrics page
- 紧凑播放页在封面与控制键之间新增三行自动滚动的同步歌词，点击歌词（或右上角按钮）进入全屏歌词页

## 0.2.2 - 2026-08-22

### Fixed / 修复

- The iOS app icon never showed — the icon set contained no image; the gold-spiral icon is now rendered from the shared artwork with the same composition as macOS
- The iOS Home Screen name showed "KumoneIOS" (`PRODUCT_DISPLAY_NAME` is not a real build setting); it now displays "Kumone" via `CFBundleDisplayName`
- iOS 图标一直不显示的问题（图标集里没有任何图片）；现从共享素材按 macOS 相同构图渲染金色旋涡图标
- iOS 主屏名称显示为「KumoneIOS」的问题（`PRODUCT_DISPLAY_NAME` 并非有效构建设置）；现通过 `CFBundleDisplayName` 显示为「Kumone」

### Improved / 改进

- The iOS bundle identifier is now `sb.moe.kumone`, distinct from the macOS app (`im.missuo.Kumone` stays unchanged so Sparkle updates keep working)
- iOS 的 bundle ID 改为 `sb.moe.kumone`，与 macOS 区分（macOS 保持 `im.missuo.Kumone` 不变，确保 Sparkle 升级不受影响）

## 0.2.1 - 2026-08-22

### Added / 新增

- Now Playing gains a like command: the hearted state syncs with the app and can be toggled from CarPlay / Control Center contexts
- 系统 Now Playing 接入「喜欢」：红心状态与 App 内双向同步，可在 CarPlay / 控制中心相关场景切换

### Fixed / 修复

- iOS audio stopped when the app left the foreground: `INFOPLIST_KEY_UIBackgroundModes` is not a real build setting and was silently ignored, so the built Info.plist had no background-audio declaration; it now comes from a partial Info.plist merged into the generated one
- iOS 应用退到后台后音频停止的问题：`INFOPLIST_KEY_UIBackgroundModes` 并非有效构建设置、被静默忽略，构建产物缺少后台音频声明；现改由部分 Info.plist 与自动生成内容合并提供

## 0.2.0 - 2026-08-21

### Added / 新增

- iOS and iPadOS support: cross-platform core (KumoneCore), adaptive layouts for compact and regular widths, and an `ios/` app workspace (#5, contributed by @MikeChongCan)
- Every release now ships an unsigned iOS IPA alongside the macOS build (sideload with your own signing)
- The macOS build is now Universal 2 — Intel Macs are supported (#7)
- iOS 与 iPadOS 支持：跨平台核心（KumoneCore）、紧凑/常规宽度自适应布局，以及 `ios/` 应用工程（#5，由 @MikeChongCan 贡献）
- 每次发版现在会同时附带无签名的 iOS IPA（自行签名侧载）
- macOS 构建改为 Universal 2，支持 Intel Mac（#7）

### Fixed / 修复

- Toolbar availability check missed the iOS clause, breaking the iOS build against the iOS 18 target
- Player bar's bottom fade no longer bleeds over the sidebar's corner
- The iOS app-shell Xcode project was silently excluded by .gitignore; it is now reconstructed via XcodeGen (`ios/project.yml`) and checked in, with the missing launch-screen key added so the app no longer letterboxes
- The sidebar divider's resize cursor no longer leaks onto the immersive now-playing page (#6)
- 工具栏可用性判断缺少 iOS 条件，导致 iOS 18 目标编译失败的问题
- 播放条底部渐变不再溢出覆盖侧边栏底角
- iOS app 壳工程曾被 .gitignore 静默排除；现改由 XcodeGen（`ios/project.yml`）生成并入库，并补上缺失的启动屏声明，App 不再上下黑边
- 侧边栏分隔条的拖拽光标不再泄漏到沉浸播放页上（#6）

### Improved / 改进

- Player chrome clearance is now derived from shared layout constants instead of scattered magic numbers
- The Home page no longer shows a sign-in card for anonymous users; the login entry lives only in the sidebar / 我的 tab
- 播放条净空高度改由共享布局常量推导，替代分散的魔数
- 未登录时首页不再显示登录卡片，登录入口仅保留在侧边栏 / 「我的」中

## 0.1.9 - 2026-08-17

### Fixed / 修复

- Scrolling long playlists could loop endlessly around the middle and never reach the bottom — caused by nested lazy stacks fighting over height estimation; list pages now use a plain outer container with lazy rows and fixed row heights (#3)
- The player bar and lyrics/queue panels now persist across page navigation instead of re-attaching per page (#4, contributed by @sld272)
- 长歌单滚动到中部时可能无限循环、无法到达底部的问题 —— 嵌套懒加载容器的高度估算互相干扰所致；列表页改为普通外层容器 + 懒加载行 + 固定行高（#3）
- 播放条与歌词/队列面板改为跨页面持久化，不再随页面切换重新挂载（#4，由 @sld272 贡献）

## 0.1.8 - 2026-08-17

### Added / 新增

- Desktop lyrics (LyricsX-style): a floating, always-on-top lyric line with translation, toggled from the player bar or Settings; draggable with center snapping, position persisted, excluded from screenshots, visible across all Spaces and full-screen apps
- 桌面歌词（LyricsX 风格）：悬浮置顶显示当前歌词与翻译，播放条或设置中开关；可拖动（带中线磁吸）、位置持久化、不出现在截图中、所有空间与全屏应用上可见

## 0.1.7 - 2026-08-16

### Fixed / 修复

- The like button in the player bar never actually rendered — the marquee title column pushed it out of the fixed-width section; it now always shows whenever a track is loaded
- 播放条的红心按钮此前从未真正显示（跑马灯标题列把它挤出了固定宽度区域）；现在只要有歌曲加载就始终显示

### Improved / 改进

- Release notes are now structured by change category with English and Chinese stacked under each section (GitHub Releases and Sparkle update notes)
- 更新说明改为按变更分类组织，每节内英文在上、中文在下（GitHub Release 与 Sparkle 更新弹窗同步生效）

## 0.1.6 - 2026-08-16

### Improved / 改进

- The "+" button next to Created Playlists now anchors to the trailing edge aligned with the playlist rows, independent of header text length in any language
- 「创建的歌单」的加号按钮改为尾部锚定并与歌单行右缘对齐，位置不再受各语言标题长度影响

## 0.1.5 - 2026-08-16

### Added / 新增

- Radar Playlists section on Home (Personal Radar / Chinese / Western / Japanese — personalized per account)
- English localization; the app follows the system language
- 首页「雷达歌单」专区（私人雷达 / 华语 / 欧美 / 日系，按账号个性化生成）
- 英文界面，App 跟随系统语言

### Fixed / 修复

- Cloud Disk always showed "no songs" — the real API nests song data under `privateCloud`/`simpleSong` and serves numeric quota fields, which broke decoding
- 音乐云盘始终显示「没有歌曲」的问题（真实接口把歌曲数据嵌在 `privateCloud`/`simpleSong` 里、容量字段为数字，导致解码失败）

## 0.1.4 - 2026-08-16

### Fixed / 修复

- New accounts (or accounts with little listening history) got a raw decoding error on the Daily Recommendations page because the API returns `data: null`; related endpoints (Personal FM, Heartbeat Mode, Cloud Disk) hardened the same way
- 新账号或听歌历史不足时，每日推荐接口返回空数据（`data: null`）导致页面报「数据解析失败」的问题；相关接口（私人漫游、心动模式、云盘）同步加固

### Improved / 改进

- Daily Recommendations now shows a friendly empty state, and decoding errors no longer surface raw error details to the user
- 每日推荐无数据时显示友好的空状态提示；解析错误不再向用户展示原始错误详情

## 0.1.3 - 2026-08-16

### Fixed / 修复

- "Play All" on a playlist failed silently (and the player bar never appeared) when every track was gray; it now matches the track list behavior and keeps gray tracks when unblocking is enabled (#1)
- 歌单「播放全部」在整单灰色歌曲时静默失败、播放条不出现的问题（现在与列表行为一致，解锁开启时保留灰色歌曲）（#1）

### Improved / 改进

- The player bar is now always visible with a placeholder idle state, removing the first-play layout jump (#1)
- 播放条改为常驻：未播放时显示占位状态，消除首次播放时的布局跳动，也不再遮挡列表底部（#1）

## 0.1.2 - 2026-08-16

### Improved / 改进

- The window toolbar (sidebar toggle, page title, search field) is hidden while the immersive now-playing page is open
- Tightened the sidebar's leading insets for a more compact navigation and playlist list
- 沉浸播放页打开时隐藏窗口工具栏（侧边栏折叠按钮、页面标题与搜索框不再露出）
- 收紧侧边栏行的左侧留白，导航与歌单列表更紧凑

## 0.1.1 - 2026-08-16

### Fixed / 修复

- Switching back to Home from other pages jittered the sidebar and flashed skeletons (Home and Explore page state is now kept across sidebar switches, no reloading)
- 从每日推荐等页面切回推荐时，侧边栏抖动、首页闪骨架屏的问题（首页与精选的页面状态现在跨切换保留，不再重复加载）

## 0.1.0 - 2026-08-16

### Added / 新增

- First public release
- QR code login with locally persisted, auto-refreshed cookies
- Home: daily recommendations, Personal FM, Heartbeat Mode, recommended playlists, charts, new albums, recommended artists
- Explore: category playlists with infinite scrolling
- Playback: Standard to Hi-Res quality, shuffle / repeat, play queue, gray track detection with third-party source unblocking
- Immersive now-playing page: artwork-tinted gradient backdrop with large synced lyrics
- Library: liked songs, playlists, albums, artists, recently played, cloud disk
- Search: aggregate / songs / artists / albums / playlists
- System integration: media keys, Control Center Now Playing, scrobbling
- Built-in Sparkle automatic updates
- 首个公开版本
- 扫码登录，Cookie 本地持久化、自动续期
- 推荐页：每日推荐、私人漫游、心动模式、推荐歌单、排行榜、新碟上架、推荐歌手
- 精选页：分类歌单无限滚动
- 播放：标准 ~ Hi-Res 音质、随机 / 循环、播放队列、灰色歌曲识别与第三方音源解锁
- 沉浸播放页：封面取色渐变背景、大字同步歌词
- 音乐库：喜欢的音乐、歌单、专辑、歌手、最近播放、音乐云盘
- 搜索：综合 / 单曲 / 歌手 / 专辑 / 歌单
- 系统集成：媒体键、控制中心 Now Playing、听歌打卡
- 内置 Sparkle 自动更新
