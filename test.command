#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
zsh build.command
mkdir -p .build/previews
.build/LPDP.app/Contents/MacOS/LPDP --self-test "$PWD/.build/previews/Preview.png"
