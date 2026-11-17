#!/bin/bash
# Double-click: export every .itmz under the parent folder to ~/Desktop/itmz-export
cd "$(dirname "$0")" || exit 1
ROOT="${1:-${ITMZ_ROOT:-$(cd .. && pwd)}}"
OUT="${2:-$HOME/Desktop/itmz-export}"
python3 -m itmz export "$ROOT" -f md,opml,html,mm,json -o "$OUT" --overwrite
echo; echo "完成：$OUT"; echo "按回车关闭"; read -r
