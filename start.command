#!/bin/bash
# Double-click to start itmz-studio. Map library = parent folder of this tool,
# or set ITMZ_ROOT, or pass a folder as first argument.
cd "$(dirname "$0")" || exit 1
ROOT="${1:-${ITMZ_ROOT:-$(cd .. && pwd)}}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 Python 3：请先运行  xcode-select --install  或  brew install python"; read -r; exit 1
fi
exec python3 -m itmz serve "$ROOT"
