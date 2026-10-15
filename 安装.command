#!/bin/bash
# 双击运行：编译「截图翻译视频下载」并安装到「应用程序」
cd "$(dirname "$0")" || exit 1
APP="截图翻译视频下载.app"
echo "== 截图翻译视频下载 安装 =="
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "需要先装苹果的「命令行开发工具」，马上会弹出安装窗口，点「安装」。"
  echo "装好之后，再双击一次「安装.command」。"
  xcode-select --install
  read -n 1 -s -r -p "按任意键关闭…"; exit 1
fi
rm -rf build && mkdir -p "build/$APP/Contents/MacOS" "build/$APP/Contents/Resources"
echo "正在编译…（约 30 秒）"
OUT="build/$APP/Contents/MacOS/JietuFanyi"
build_ok=0
try_build() { # $1=说明 其余=命令前缀
  local label="$1"; shift
  echo "-> 尝试：$label"
  if "$@" -O -swift-version 5 -target arm64-apple-macos14.0 src/*.swift -o "$OUT" 2>build/err.log; then build_ok=1; echo "   成功"; else echo "   不行（$(grep -m1 -o 'error:.*' build/err.log | cut -c1-90)）"; fi
}
try_build "默认工具链" swiftc
# 如果 Xcode 装了，用 Xcode 自带的工具链
for X in /Applications/Xcode*.app; do
  [ $build_ok = 1 ] && break
  [ -d "$X/Contents/Developer" ] && try_build "$X" env DEVELOPER_DIR="$X/Contents/Developer" xcrun swiftc
done
# 命令行工具里有多个系统开发包时，挨个试（从新到旧）
for SDK in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
  [ $build_ok = 1 ] && break
  try_build "$(basename "$SDK")" swiftc -sdk "$SDK"
done
if [ $build_ok != 1 ]; then
  echo; cat build/err.log | head -20
  echo; echo "编译失败：可用的开发包："; ls /Library/Developer/CommandLineTools/SDKs/
  echo "请把这个窗口截图发给 Claude。"; read -n 1 -s -r -p "按任意键关闭…"; exit 1
fi
cp src/Info.plist "build/$APP/Contents/Info.plist"
cp src/AppIcon.icns "build/$APP/Contents/Resources/AppIcon.icns"
# 签名时把「身份」固定成软件 ID，减少更新后的权限变化；系统仍可能要求重新授权
codesign --force --sign - --identifier com.zurenze.desktop-translator \
  -r='designated => identifier "com.zurenze.desktop-translator"' "build/$APP"
pkill -x DesktopTranslator 2>/dev/null; pkill -x Lingxi 2>/dev/null; pkill -x JietuFanyi 2>/dev/null; sleep 0.5
rm -rf "/Applications/桌面翻译器.app" "/Applications/灵犀.app"   # 旧名字的版本
rm -rf "/Applications/$APP" && cp -R "build/$APP" /Applications/
touch "/Applications/$APP"   # 让访达刷新图标
open "/Applications/$APP"
echo "✅ 已安装到「应用程序」并启动：桌面右侧是奶油金悬浮入口，点开即可使用工具面板；菜单栏有「译」。"
echo "⚠️ 首次使用或更新后如需授权：系统设置 → 隐私与安全性 →「辅助功能」和「录屏与系统录音」里打开「截图翻译视频下载」（旧的「桌面翻译器」「灵犀」可点 − 移除）。"
