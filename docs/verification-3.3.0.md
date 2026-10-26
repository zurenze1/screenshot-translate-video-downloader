# 3.3.0 验证范围

日期：2026-10-26。Apple Silicon、macOS 26 本机验证。

- 新增原生 ScreenCaptureKit 录屏：区域拖选、Esc 取消、独立电脑声音和麦克风开关、普通预览命名、快速保存。
- 真实区域录屏输出 1480×960 H.264 MP4，19.38 秒，可完整解码；开启电脑声音时含 48kHz 双声道 AAC。关闭电脑声音和麦克风后输出只有视频轨。
- 普通模式的预览与命名保存、快速模式自动保存通过。关闭预览后重新打开可继续保存；同名保存自动追加序号，原文件保留。
- 录制中关闭窗口与退出受保护；再次打开录屏入口保持录制状态，停止后等文件写完才进入预览。
- 通过本机 Eagle API 导入两条合成画面测试视频，查询目标文件夹确认新增两项，名称、备注和字节数一致，中转站原件仍在。
- 应用重启后仍可读取中转站原有素材；自定义工具及头像入口保留。
- 本机完整版本与公开版本分别构建，严格签名完整性检查通过。公开版只发布本次授权范围的源码和程序，不包含本机额外模块、私人插画、原始媒体、Cookie 或配置。

未实测：真人麦克风采样、多显示器、全屏 Space、macOS 14/15 真机兼容。公开版最低构建目标保持 macOS 14，录屏入口在 macOS 15 以下提示不支持；本机完整版本仍要求 macOS 26。原有翻译、各平台下载、去水印及剪辑导出未进行完整回归。界面审美与实际工作流仍待使用者验收。

发布包使用 ad hoc 签名，没有 Apple Developer ID 公证。多个时间区间批量导出不在本轮范围。

## 来源

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Nonstrict 的 MIT 示例](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example)：坐标、Retina 处理参考。
- [Eagle 本机 API](https://api.eagle.cool/item/add-from-path)：独立接入，没有云端密钥。

没有复制未声明许可证的刘老大项目源码。
