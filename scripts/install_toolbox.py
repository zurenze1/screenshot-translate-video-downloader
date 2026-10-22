#!/usr/bin/env python3
"""Build and install Toolbox locally while retaining the previous application."""
from datetime import datetime
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import time
import sys

repo = Path(__file__).resolve().parent.parent
stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
work = repo / '.work' / 'install-backups' / stamp
app = work / 'build/工具箱.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
(contents / 'Resources').mkdir()
compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
command = [compiler]
if sdk.exists():
    command.extend(['-sdk', str(sdk)])
command.extend(['-O', '-swift-version', '5', '-target', 'arm64-apple-macos14.0'])
command.extend(str(path) for path in sorted((repo / 'src').glob('*.swift')))
command.extend(['-o', str(contents / 'MacOS/JietuFanyi')])
print('正在编译工具箱…', flush=True)
subprocess.run(command, check=True)
shutil.copy2(repo / 'src/Info.plist', contents / 'Info.plist')
shutil.copy2(repo / 'src/AppIcon.icns', contents / 'Resources/AppIcon.icns')
subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'com.zurenze.desktop-translator', '-r=designated => identifier "com.zurenze.desktop-translator"', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
if '--build-only' in sys.argv:
    print('构建已完成：' + str(app), flush=True)
    raise SystemExit(0)
target = Path('/Applications/工具箱.app')
legacy = Path('/Applications/截图翻译视频下载.app')
for path in [target, legacy]:
    if path.exists() and not path.is_symlink():
        info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'com.zurenze.desktop-translator':
            raise RuntimeError('安装位置已有其他应用，请先更换目标位置：' + str(path))
subprocess.run(['pkill', '-TERM', '-x', 'JietuFanyi'], check=False)
for attempt in range(50):
    if subprocess.run(['pgrep', '-x', 'JietuFanyi'], stdout=subprocess.DEVNULL).returncode != 0:
        break
    time.sleep(0.1)
else:
    raise RuntimeError('工具箱尚未退出，已保留新构建，请稍后重试安装。')
if target.exists() and not target.is_symlink():
    shutil.move(str(target), str(work / 'previous-工具箱.app'))
subprocess.run(['ditto', str(app), str(target)], check=True)
if legacy.exists() and not legacy.is_symlink():
    shutil.move(str(legacy), str(work / 'previous-截图翻译视频下载.app'))
if not os.path.lexists(legacy):
    legacy.symlink_to(target)
if legacy.is_symlink():
    subprocess.run(['chflags', '-h', 'hidden', str(legacy)], check=True)
subprocess.run(['open', str(target)], check=True)
print('工具箱已安装并启动。原应用备份保存在：' + str(work), flush=True)
