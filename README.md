## 3.3.1：视频素材采集

工具入口、悬浮菜单和窗口标题统一使用“视频素材采集”。快捷键仍为⌥V，链接解析、画质选择、片段截取以及原有保存位置、历史记录保持。

# 祖仁泽的工具箱 · 3.3.1 公开版

Mac 桌面上的创作小工具，共用一个悬浮入口和菜单栏。

**[下载 Mac 安装包](https://github.com/zurenze1/screenshot-translate-video-downloader/releases/latest)** · [全部发布版本](https://github.com/zurenze1/screenshot-translate-video-downloader/releases)

## 3.3.0 更新（2026-10-26）

新增区域 / 全屏录屏：电脑声音与麦克风独立选择。普通模式停止后可预览、命名并保存到中转站；快速模式停止后自动保存。录屏采用 Apple ScreenCaptureKit，需要 macOS 15 或更新版本，不依赖 ffmpeg。

中转站选中素材后，点击“存入 Eagle…”可读取本机 Eagle 文件夹，逐项命名并填写共同备注。导入后查询目标文件夹核对新增素材，保留中转站原件。请保持 Eagle 开启并载入素材库；这项功能不需要 API 密钥。

## 3.2.2 更新（2026-10-25）

修复翻译框、视频下载和片段截取在切换到其他应用后难以重新唤起、点击时消失或无法输入的问题。重新打开会恢复最小化的窗口并取得输入焦点；翻译框不再因失去焦点而自动关闭，已有文字与译文会保留。翻译框“固定”仍可切换置顶。

工具箱入口在集合窗口持有焦点时再次点击会收起；被其他应用遮挡时再次点击会恢复显示。

## 每个工具

| 工具 | 用途与入口 | 主要源码 |
|---|---|---|
| 翻译框 | 中英互译、选中文字翻译、截图识字；⌥A / ⌥D / ⌥S | [Translator.swift](src/Translator.swift)、[main.swift](src/main.swift) |
| 中转站 | 截图、图片、视频和文件副本；分类、搜索、批量复制、可恢复删除；⌥Z | [Shelf.swift](src/Shelf.swift)、[RelayStore.swift](src/RelayStore.swift) |
| 录屏 | 区域 / 全屏、电脑声音与麦克风、预览命名、快速存入中转站 | [ScreenRecorder.swift](src/ScreenRecorder.swift) |
| 存入 Eagle | 选中中转站素材 → 选文件夹 → 命名与备注 → 导入并核对 | [EagleExport.swift](src/EagleExport.swift) |
| 视频下载 | 粘贴链接、选择清晰度与保存位置、保存本机下载记录；⌥V | [Downloader.swift](src/Downloader.swift) |
| 片段截取 | 本地或在线片段截取、字幕处理、画面区域处理；⌥C | [ClipEditor.swift](src/ClipEditor.swift)、[Watermark.swift](src/Watermark.swift) |

这些工具共用同一个安装包，可从工具箱单独打开。

另两件独立工具：**[自媒体工作台](https://github.com/zurenze1/content-workbench)**（选题、素材、脚本和发布复盘）、**[人生档案](https://github.com/zurenze1/life-archive)**（[Mac 下载](https://github.com/zurenze1/life-archive/releases/latest)）。

本公开版按作者要求排除拾片与屏幕中文，其源码、资源和安装包均未加入。首页采用系统图标，未分发本机 Eagle 插画。

## 安装

适用 Apple Silicon（M 系列）Mac。构建最低目标为 macOS 14，当前仅在本机 macOS 26 上验证。解压下载包，把“工具箱.app”拖到“应用程序”，再打开。

应用采用本机 ad hoc 签名，未做 Apple Developer ID 公证；首次打开可能需要在系统“隐私与安全性”中确认。截图、录屏和读取其他应用选中文字时，按需授予屏幕录制或辅助功能权限。只有开启麦克风时才会申请麦克风权限。录屏文件保存在本机，Eagle 仅使用 127.0.0.1 本机接口。

翻译框可使用 Apple 本机翻译；本机语言包可用性取决于系统版本。选择或回退到必应、谷歌、MyMemory 时，待翻译文本会发给相应服务。

视频下载需要 `yt-dlp`，合并、音频转换、片段截取需要 `ffmpeg`；这些组件未捆绑到安装包。使用 Homebrew 可执行：

```sh
brew install yt-dlp ffmpeg
```

不同网站可能要求登录或验证；不保证每个平台、每个链接均可下载。只处理你有权使用的内容。

## 录屏与 Eagle 使用

1. 打开“录屏”，选择屏幕和区域，分别设置电脑声音、麦克风。默认不录麦克风。
2. 点击“开始录制”，结束时点击“停止录制”，等待 MP4 写入完成。
3. 普通模式会打开预览，填写名称后“保存到中转站”。快速模式直接使用时间戳命名保存。
4. 关闭未保存的预览不会删除文件；本次运行重新打开录屏可继续保存。重启后可从“打开录屏暂存”找回。
5. 在中转站选择一个或多个素材，点击“存入 Eagle…”，选文件夹、命名、填写备注后导入。
6. 若提示未确认，请先在 Eagle 核对，再选择未入库项重试，避免重复导入。

本轮不含多个时间区间批量截取。录屏输出最高 3840 × 2160 范围内的 H.264 MP4、最高 30 帧；按区域比例等比缩放。

## 从源码构建

需要 Python 3 与 Apple 命令行开发工具。双击 `安装.command` 会先编译、验签、保留旧应用备份再安装。仅构建而不安装：

```sh
python3 scripts/install_toolbox.py --build-only
```

构建结果及旧应用备份位于 `.work/install-backups/`，不进入源码仓库。截图、中转文件、下载记录、个人头像和自定义工具列表保存在本机；发布包不含作者的个人数据、Cookie或配置。

## 许可与来源

本仓库自有代码沿用 [MIT License](LICENSE)。录屏使用 Apple 官方 ScreenCaptureKit，开发时参考 [Nonstrict MIT 示例](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example) 的坐标与 Retina 处理方式；没有复制未声明许可证的刘老大源码。Eagle 依据[官方本机 API 文档](https://api.eagle.cool/)独立接入。未捆绑的外部组件按各自许可使用。`docs/` 中的旧版演示保留作历史资料；当前功能与平台要求以本页和对应 Release 为准。
