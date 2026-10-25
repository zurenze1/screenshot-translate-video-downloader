# 祖仁泽的工具箱 · 3.2.2 公开版

Mac 桌面上的四件创作小工具，共用一个悬浮入口和菜单栏。

**[下载 Mac 安装包](https://github.com/zurenze1/screenshot-translate-video-downloader/releases/latest)** · [全部发布版本](https://github.com/zurenze1/screenshot-translate-video-downloader/releases)

## 3.2.2 更新（2026-10-25）

修复翻译框、视频下载和片段截取在切换到其他应用后难以重新唤起、点击时消失或无法输入的问题。重新打开会恢复最小化的窗口并取得输入焦点；翻译框不再因失去焦点而自动关闭，已有文字与译文会保留。翻译框“固定”仍可切换置顶。

工具箱入口在集合窗口持有焦点时再次点击会收起；被其他应用遮挡时再次点击会恢复显示。

## 每个工具

| 工具 | 用途与入口 | 主要源码 |
|---|---|---|
| 翻译框 | 中英互译、选中文字翻译、截图识字；⌥A / ⌥D / ⌥S | [Translator.swift](src/Translator.swift)、[main.swift](src/main.swift) |
| 中转站 | 截图、图片、视频和文件副本；分类、搜索、批量复制、可恢复删除；⌥Z | [Shelf.swift](src/Shelf.swift)、[RelayStore.swift](src/RelayStore.swift) |
| 视频下载 | 粘贴链接、选择清晰度与保存位置、保存本机下载记录；⌥V | [Downloader.swift](src/Downloader.swift) |
| 片段截取 | 本地或在线片段截取、字幕处理、画面区域处理；⌥C | [ClipEditor.swift](src/ClipEditor.swift)、[Watermark.swift](src/Watermark.swift) |

四件工具共用同一个安装包。每件都能从工具箱单独打开；没有为共享源码复制四套仓库。

另两件独立工具：**[自媒体工作台](https://github.com/zurenze1/content-workbench)**（选题、素材、脚本和发布复盘）、**[人生档案](https://github.com/zurenze1/life-archive)**（[Mac 下载](https://github.com/zurenze1/life-archive/releases/latest)）。

本公开版按作者要求排除拾片与屏幕中文，其源码、资源和安装包均未加入。首页采用系统图标，未分发本机 Eagle 插画。

## 安装

适用 Apple Silicon（M 系列）Mac。构建最低目标为 macOS 14，当前仅在本机 macOS 26 上验证。解压下载包，把“工具箱.app”拖到“应用程序”，再打开。

应用采用本机 ad hoc 签名，未做 Apple Developer ID 公证；首次打开可能需要在系统“隐私与安全性”中确认。截图和读取其他应用选中文字时，按需授予屏幕录制或辅助功能权限。

翻译框可使用 Apple 本机翻译；本机语言包可用性取决于系统版本。选择或回退到必应、谷歌、MyMemory 时，待翻译文本会发给相应服务。

视频下载需要 `yt-dlp`，合并、音频转换、片段截取需要 `ffmpeg`；这些组件未捆绑到安装包。使用 Homebrew 可执行：

```sh
brew install yt-dlp ffmpeg
```

不同网站可能要求登录或验证；不保证每个平台、每个链接均可下载。只处理你有权使用的内容。

## 从源码构建

需要 Python 3 与 Apple 命令行开发工具。双击 `安装.command` 会先编译、验签、保留旧应用备份再安装。仅构建而不安装：

```sh
python3 scripts/install_toolbox.py --build-only
```

构建结果及旧应用备份位于 `.work/install-backups/`，不进入源码仓库。截图、中转文件、下载记录、个人头像和自定义工具列表保存在本机；发布包不含作者的个人数据、Cookie或配置。

## 许可与来源

本仓库自有代码沿用 [MIT License](LICENSE)。未捆绑的外部组件按各自许可使用。`docs/` 中的旧版演示保留作历史资料；当前功能与平台要求以本页和对应 Release 为准。
