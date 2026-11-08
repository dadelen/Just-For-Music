# V2.1 开发交付报告

本文记录 2026-11-07 的本地预览构建。公开源码版本 Just-For-Music 1.0 的信息见 [项目主页](../README.zh-CN.md)。

## 交付物

- `dist/Apple Music Lyrics.app`：2.1.0 本地应用。
- `dist/release/Apple-Music-Lyrics-2.1.0-macos-arm64.dmg`：安装镜像。
- `dist/release/Apple-Music-Lyrics-2.1.0-macos-arm64.zip`：应用压缩包。
- `dist/release/SHA256SUMS.txt`：两个归档的 SHA-256。
- `dist/verification/`：本地编译、测试及产物检查记录。生成物不纳入 Git。

应用显示名暂保留 Apple Music Lyrics，独立预览 Bundle ID 为 `local.applemusiclyrics.v2`。偏好设置与原版分开，诊断日志位于 `~/Library/Logs/Apple Music Lyrics V2/`。最终品牌和发布标识由维护者确定，可通过构建变量替换。

没有创建远程仓库，没有修改已有 remote，没有 push、tag 或发布 Release。当前 `origin` 仍指向原项目；后续发布前由用户改为自己的仓库。本地包不带更新仓库配置，因此不会检查或提示下载原作者版本。

## 已实现

| 范围 | 实现与边界 |
| --- | --- |
| 架构 | 主程序和播放助手仅 arm64；构建、归档、更新资产选择和 CI 均走 Apple Silicon 路径。 |
| 状态栏 | 单一状态项，独立歌词视口和三个播放按钮；完整文本参与逐字绘制，按播放位置滚动；按钮固定、悬停反馈和辅助功能标签。歌词视口裁剪，避免文字盖住按钮。 |
| 自适应 | 自动模式根据屏幕宽度和刘海选择完整/紧凑视口；提供手动完整、紧凑和仅图标。没有使用私有 API 查询剩余空间，系统仍可隐藏状态项。 |
| KTV 空档 | 展示层插入三点，保留原始时间戳；仅使用已确认的 TTML 结束时间、下一行起点及歌曲时长，阈值 1.5 秒。未知边界不伪造。 |
| 播放菜单 | 真实封面、右侧居中的歌曲信息与控制按钮、可拖动进度条；底部只保留等宽设置和退出，不显示歌词或译文。 |
| 设置 | 独立窗口，五组配置；保留缓存刷新、颜色、字号、滚动、空档、窗口、翻译、更新及日志入口。 |
| 系统材质 | 26+ 使用 NSGlassEffectView，旧系统使用 NSVisualEffectView；没有蓝色或其他自定义底色。降低透明度使用系统不透明背景，动态文本颜色随外观变化。 |
| 双栏浮窗 | Small 640 × 260 pt / Large 880 × 380 pt；不含可缩放 styleMask；拖动、按显示器存储位置、置顶、跨桌面和全屏配置保留。切尺寸保持顶部位置并约束到可见屏幕。 |
| 黑胶 | 独立 CALayer 组件，黑色同心纹理、圆形真实封面、白色简化唱针；旋转 1.8 秒一圈，暂停/恢复使用 layer 时间控制，隐藏或减少动态效果时停止旋转。参考图未作为整图背景嵌入。 |
| 歌词 | 保留原有图层逐字渲染、手动滚动及点击跳转；译文为原文字号的 80%，较弱颜色，无逐字高亮。已有音译可单独显示。 |
| 自动翻译 | NaturalLanguage 识别全文及单行；中文跳过，同一句中外文混合整句跳过。外语按语言分组、合并重复句，使用 Apple Translation；已有中文缓存译文优先。 |
| 翻译任务 | 语言识别后台处理、异步批量翻译、磁盘缓存、UUID 隔离切歌任务，源歌词时间保持不变。macOS 13–14 不调用机器翻译；缺少资源时提示从设置进入系统下载流程。 |
| 翻译策略 | 自动翻译默认关闭。26.4+ 使用 lowLatency，较旧支持系统走基础接口。已有译文缓存可复用。 |
| 共享来源 | UI 与黑胶共享既有 PlaybackMonitor 状态；没有为黑胶或译文新增播放轮询。封面共享 ArtworkService，按歌曲变更加载。 |
| 清理 | 删除导出、快捷键、锁定、穿透、Option 监听、旧双浮窗模式及自由缩放逻辑与配置。缓存解析和播放监测保留。 |
| 发布 | 保留 MIT License、原始版权和 README 来源；应用包内附 License。更新地址通过 UPDATE_REPOSITORY 配置，下载及校验保留。 |

## 实际编译与测试

环境实际输出：macOS 27.2（26B123），Xcode 27.2（27B52），Swift 6.4.2，arm64。最低部署目标仍为 macOS 13；代码构建需要 macOS SDK 26.4+。

| 检查 | 结果 |
| --- | --- |
| 最终 `swift test` | **35 项，33 通过，2 跳过，0 失败**。跳过项为需显式启用的 Music 缓存和系统翻译集成测试。 |
| 核心回归 | 原有缓存匹配、TTML 时间解析、更新下载与校验、日志测试通过。未重写 PlaybackMonitor 或 MusicPlaybackController。 |
| 新增确定性测试 | 前奏/间奏/尾奏边界、无可靠结束时间、重叠与短空档、简繁中文和混合语言过滤、日文汉字识别、已有中文译文优先、缓存键与损坏缓存、同名不同专辑隔离通过。 |
| 黑胶测试 | 两档布局圆形及封面边界、1.8 秒周期、暂停时间保留、恢复连续时间、隐藏后暂停通过。此为图层状态测试，不等于屏幕视觉验收。 |
| 单独启用系统翻译测试 | 实际查询显示英译中资源未安装，测试按条件跳过；没有偷偷下载模型，也没有把它记作翻译成功。 |
| 单独启用真实 Music 缓存测试 | 启动后持续等待，没有得到结果，已终止本次测试进程。桌面锁定，无法确认是否在等待权限；此项**未通过实机验收**。没有切歌或播放音乐。 |
| Release 构建 | `VERSION=2.1.0 ./scripts/create-release-artifacts.sh` 成功。 |
| 架构 | 对主程序与播放助手执行 `lipo -archs`，均只有 `arm64`。 |
| 旧系统链接 | `otool -l` 确认 Translation.framework 使用弱链接；运行时 API 均有可用性检查。不能替代旧系统实际运行。 |
| 签名 | `codesign --verify --deep --strict` 通过，签名方式为 ad-hoc。 |
| 归档 | ZIP 解压校验及包内 Info.plist 比对通过；SHA-256 全部匹配；`hdiutil verify` 验证 DMG 有效。 |
| 发布脚本 | 所有 shell 脚本通过 `bash -n`，工作流 YAML 解析通过；GitHub CI 尚未远程执行。 |
| 源码卫生 | `git diff --check` 通过。 |

构建输出唯一需要记录的工具提示是当前系统对 `hdiutil create` 的弃用警告；镜像仍成功创建和验证。编译没有记录到 Swift 错误或警告。

## 尚未完成及原因

1. **真实窗口视觉和交互验收**：桌面工具明确报告 Mac 已锁屏，无法自动解锁；未伪造截图，也未将源码检查算作 UI 验收。液态玻璃实际观感、按钮命中、长标题、长译文布局仍待明天检查。
2. **真实系统译文与下载弹窗验收**：系统资源未安装，锁屏下无法完成下载授权；代码及资源状态检查已就绪，实际译文质量和系统弹窗尚未验证。
3. **真实歌曲同步和播放控制验收**：没有完成 Apple Music 权限后的运行测试；集成测试等待后已终止。需要实机确认切歌、播放/暂停、菜单拖动进度、点击歌词和封面。
4. **跨系统/显示器/全屏验证**：当前仅在一台系统上编译测试，未实际运行 macOS 13–14、15、26，也没有完成多显示器插拔、Space/全屏、刘海拥挤菜单栏测试。
5. **性能实测**：没有取得新版本实际播放时的 CPU、内存、掉帧数据。不能给出“无掉帧”或具体占用结论。已避免黑胶逐帧定时器，缓存状态栏字形布局，只绘制视口内字形，隐藏浮窗停止装饰旋转。
6. **自己的远程仓库、正式 Bundle ID、Developer ID 签名和公证**：按用户要求未创建仓库。当前是独立本地预览标识，正式发布配置待用户提供。

## 兼容性与性能边界

- Apple Music 的缓存结构属于未公开的数据格式，系统升级可能影响匹配；本次仅扩充可靠结束时间和翻译元数据，不替换核心获取流程。
- 菜单栏自动宽度是保守启发式，不保证检测其他状态项占用。极端空间下允许系统隐藏，用户可手动切到仅图标。
- 同一首歌中文和外语并存时按行判断；短句、汉字日文与模糊混合句存在识别不确定性，当前策略倾向跳过，不承诺零误判。
- 无可靠时间轴的歌词无法提供逐字和按行同步；无缓存时也不会自动从第三方补齐。可用数据是同步与翻译体验的前提。
- macOS 15 的翻译会话由 SwiftUI host 提供，窗口显隐和系统资源下载的生命周期需重点实机验证；26+ 已安装资源走正式独立会话。
- 翻译缓存保存在用户缓存目录，系统可清理；目前没有应用内缓存容量设置。封面内存缓存限制为 32 项，首次语言识别与模型加载的耗时尚未实测。
- 原有采样插值逻辑继续复用。应用自己的 seek 操作会清空展示时钟，外部 Music 操作仍依赖播放监测下一次采样识别。

## 明天的人工验收顺序

1. 若原版正在运行，先从原版菜单退出，避免两个同名状态项。打开 `dist/Apple Music Lyrics.app`，处理 Music 自动化权限。
2. 在 Music 播放并打开一首有逐字歌词的歌曲。检查状态栏三个按钮分别直接控制播放，点击歌词才打开菜单。
3. 完整/紧凑/仅图标逐一切换；用长歌词验证滚动与按钮不重叠。暂停、恢复、切歌、拖动进度，检查歌词和黑胶状态连续。
4. 打开菜单检查真实封面、信息居中、进度条和两个等宽入口；设置不显示实时歌词。
5. 切 Small/Large，移动浮窗到另一显示器后重启；验证圆形唱片、白色唱针、原文/译文层级、手动滚动和点击跳转。
6. 从“翻译 → 准备语言资源”下载系统资源，测试英语、日语、韩语、中文和中外文混合句；快速连续切歌确认没有串译文。关闭自动翻译后仍应保留已有缓存译文。
7. 检查系统深浅色、降低透明度、提高对比度、减少动态效果，以及全屏/多桌面。窗口不应出现人工蓝色底板。
8. 用活动监视器分别观察播放、暂停、隐藏浮窗和翻译中的 CPU/内存；记录实际数据后再决定是否优化。

## 可回退提交

| 提交 | 内容 |
| --- | --- |
| `15fc470` | Apple Silicon 构建与发布基线 |
| `59b6ccc` | V2.1 需求文档 |
| `9dbc192` | 删除旧导出与浮窗交互模式 |
| `659ddfe` | 独立状态栏控制及可靠空档进度 |
| `6036b9c` | 简洁菜单与独立设置窗口 |
| `0f5d44a` | 系统玻璃、固定双栏浮窗与黑胶；视觉和浮窗两个阶段共用一个编译检查点 |
| `f65c52f` | 本地翻译、识别过滤、缓存与切歌隔离 |
| 后续本地提交 | 最终边界修复、发布配置、文档及交付记录；使用 `git log --oneline` 查看 |

各实现检查点已执行编译和相关测试。真实 GUI 与旧系统验证没有完成，不能因提交已建立就视为完成验收。

## 文件清单

以下按原始基线 `274105f` 比较（保留的缓存和播放模块未做无关重构）：

### 新增

- `Sources/AppleMusicLyrics/ActionButton.swift`
- `Sources/AppleMusicLyrics/ArtworkService.swift`
- `Sources/AppleMusicLyrics/GlassSurface.swift`
- `Sources/AppleMusicLyrics/LocalTranslationService.swift`
- `Sources/AppleMusicLyrics/LyricsLanguageDetector.swift`
- `Sources/AppleMusicLyrics/SettingsWindowController.swift`
- `Sources/AppleMusicLyrics/TranslationCache.swift`
- `Sources/AppleMusicLyrics/VinylPlayerView.swift`
- `Tests/AppleMusicLyricsTests/LocalTranslationIntegrationTests.swift`
- `Tests/AppleMusicLyricsTests/LyricsGapTests.swift`
- `Tests/AppleMusicLyricsTests/LyricsLanguageDetectorTests.swift`
- `Tests/AppleMusicLyricsTests/VinylPlayerViewTests.swift`
- `docs/DEVELOPMENT_REPORT.md`
- `docs/REQUIREMENTS_V2.md`
- `scripts/check-build-sdk.sh`

### 修改

- `.github/workflows/release.yml`
- `CONTRIBUTING.md`
- `README.md`
- `README.zh-CN.md`
- `Resources/InstallGuide.txt`
- `Sources/AppleMusicLyrics/AppDelegate.swift`
- `Sources/AppleMusicLyrics/AppMain.swift`
- `Sources/AppleMusicLyrics/AppPreferences.swift`
- `Sources/AppleMusicLyrics/AppleMusicCacheLyricsProvider.swift`
- `Sources/AppleMusicLyrics/AppleTTMLParser.swift`
- `Sources/AppleMusicLyrics/DiagnosticLogger.swift`
- `Sources/AppleMusicLyrics/FloatingLyricsWindow.swift`
- `Sources/AppleMusicLyrics/MenuBarController.swift`
- `Sources/AppleMusicLyrics/Models.swift`
- `Sources/AppleMusicLyrics/UpdateService.swift`
- `Sources/PlaybackHelper/main.swift`
- `Tests/AppleMusicLyricsTests/UpdateServiceTests.swift`
- `scripts/create-release-artifacts.sh`
- `scripts/package-app.sh`
- `scripts/run.sh`

### 删除

- `Sources/AppleMusicLyrics/GlobalHotKeyController.swift`
- `Sources/AppleMusicLyrics/LyricsExporter.swift`
- `Tests/AppleMusicLyricsTests/LyricsExporterTests.swift`

原 `LICENSE` 原文未改动，发布时复制到应用 Resources。`PlaybackMonitor.swift`、`MusicPlaybackController.swift` 和核心播放助手逻辑继续复用。
