#!/bin/zsh
cd -- "$(dirname -- "$0")" || exit 1
if ! xcode-select -p >/dev/null 2>&1; then
  print "请先安装苹果命令行开发工具，再重新运行安装。"
  xcode-select --install
  exit 1
fi
caffeinate -i /usr/bin/python3 scripts/install_toolbox.py
result=$?
if [ "$result" -ne 0 ]; then
  print "安装尚未完成。上方显示具体原因，原应用与备份保留。"
  read -k 1 "?按任意键关闭…"
fi
exit "$result"
