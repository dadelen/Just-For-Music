# Apple Music Lyrics · V2

[English](README.md) | 简体中文

基于 [Takpap/apple-music-lyrics](https://github.com/Takpap/apple-music-lyrics) 的二次开发版本。
感谢原作者和贡献者；保留原项目 MIT License 和版权声明。本项目与 Apple 无隶属关系。

原有 Apple Music 缓存读取、TTML 解析和播放监测继续复用。此次改造围绕状态栏、系统玻璃浮窗、黑胶和本地翻译展开。

## 功能

- 一个状态项容纳原文逐字歌词，以及独立的上一首、播放/暂停、下一首按钮。
- 长歌词在完整或紧凑视口内按演唱位置滚动，按钮位置固定。提供自动、完整、紧凑和仅图标设置。
- 点击歌词打开简洁播放器：真实封面、歌曲信息、播放控制和进度条；底部仅设置、退出。
- 独立设置窗口包含常规、歌词、翻译、悬浮窗口、更新与诊断五组。
- 桌面浮窗使用系统玻璃，没有蓝色或其他自定义底色。左侧黑胶和白色唱针，右侧原文、译文及可选缓存音译。
- Small（640 × 260 pt）和 Large（880 × 380 pt）两档，不支持边缘自由缩放。窗口可拖动、置顶、记忆显示器位置，并可跨桌面及全屏显示。
- 黑胶与真实封面每 6 秒旋转一圈，唱片带有柔和的反光和阴影。歌名与歌手在唱片下方居中，暂停保留角度。
- 前奏及有可靠边界的间奏/尾奏显示三点进度，随真实播放位置高亮。低于 1.5 秒或没有可靠结束时间的空档不生成进度。
- 歌词左对齐，当前句突出显示，邻句淡化。手动滚动停止 4 秒后回到当前播放行，译文字号为原文的 80%。
- 本地识别歌词语言，优先缓存中文译文，再使用 Apple Translation。中文不翻译，**同一句中外文混合时整句不翻译**；同首歌其他纯外语行仍可翻译。
- 翻译按歌曲、源/目标语言、歌词版本及质量策略缓存，切歌隔离旧任务。翻译结果只出现在浮窗。
- 更新源可配置为自己的 GitHub Releases，保留下载与 SHA-256 校验。未配置时关闭更新检查。

已删除歌词导出、沉浸/紧凑双浮窗布局、窗口锁定、鼠标穿透、Option 临时交互、全局快捷键以及任意缩放。

## 兼容性

| 项目 | 条件 |
| --- | --- |
| CPU | 仅 Apple Silicon / arm64 |
| 最低运行系统 | macOS 13 |
| 玻璃 | macOS 26+：NSGlassEffectView；13–25：NSVisualEffectView |
| 机器翻译 | macOS 15+；13–14 仅显示已有缓存译文 |
| 翻译质量策略 | macOS 26.4+ 优先 highFidelity；更早系统使用系统可用策略 |
| 从源码构建 | Xcode 26.4+、macOS SDK 26.4+，Swift 6.3+ |

系统降低透明度时使用不透明系统背景；减少动态效果时停用黑胶旋转，保留歌词同步。
高质量策略的可用性和回退由 [Apple Translation](https://developer.apple.com/documentation/translation/translationsession/strategy) 决定。

菜单栏剩余空间没有可精确查询的公共接口。自动模式按屏幕条件选择宽度；状态项仍可能被系统隐藏。可手动改为紧凑或仅图标，重新打开应用可进入设置。

## 歌词来源与限制

应用只读以下 Music.app 缓存，不向第三方歌词或翻译 API 发送歌词：

```text
~/Library/Caches/com.apple.Music/Cache.db
~/Library/Caches/com.apple.Music/fsCachedData/
```

在 Music.app 播放 Apple Music 歌曲，并打开其歌词面板，让系统先缓存歌词。缓存按歌曲信息匹配；没有对应缓存时，应用会提示等待。导入的本地音乐、无歌词歌曲以及系统已清理的缓存不保证可用。该缓存格式由 Apple 私有实现控制，系统升级可能影响读取。

逐字精度取决于 TTML：多个字符共用一个 span 时，在该 span 时间范围内插值，不声称每个字符都有独立时间戳。语言识别对短句或模糊混合语言采用保守策略，可能跳过部分外语行。

## 构建、测试与运行

```bash
swift test
VERSION=2.1.0 ./scripts/package-app.sh
open "dist/Apple Music Lyrics.app"
```

应用位于 `dist/Apple Music Lyrics.app`。本地预览默认使用独立标识 `local.applemusiclyrics.v2`，避免覆盖原版偏好设置。此标识可由 `BUNDLE_IDENTIFIER` 环境变量替换。应用显示名暂保留 Apple Music Lyrics。

首次使用需要允许应用控制 Music。没有歌词时，先在 Music 打开歌词，再在设置中“重新读取歌词缓存”。语言资源未安装时，从“翻译 → 准备语言资源…”进入系统下载流程；取消或失败不会阻止原文显示。

本地包使用 ad-hoc 签名，未做 Developer ID 公证。对外分发应配置自己的签名身份和公证流程。

## 打包与自有更新源

```bash
VERSION=2.1.0 ./scripts/create-release-artifacts.sh
```

生成 arm64 ZIP、DMG 和 `SHA256SUMS.txt` 到 `dist/release/`。包内保留 MIT License。

拥有自己的仓库后再配置（下方为占位示例，请替换）：

```bash
BUNDLE_IDENTIFIER=com.yourname.lyrics \
UPDATE_REPOSITORY=yourname/your-repository \
VERSION=2.1.0 ./scripts/create-release-artifacts.sh
```

本次开发没有创建、修改或推送远程仓库，也没有发布 Release。本地默认不嵌入更新源。
仓库的 Release 工作流只在日后推送版本标签时运行，并使用所在仓库作为更新源；发布前设置仓库变量 `BUNDLE_IDENTIFIER`。

## 验收与诊断

设置中的“更新与诊断”支持查看、复制和定位日志。日志含歌曲元数据和错误信息，分享前请自行检查。

详细实现状态、测试记录、文件清单及人工验收项见 [开发交付报告](docs/DEVELOPMENT_REPORT.md)。
产品规格见 [V2.1 需求文档](docs/REQUIREMENTS_V2.md)，开发约束见 [CONTRIBUTING.md](CONTRIBUTING.md)。
