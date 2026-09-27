#!/bin/bash
# J47 internal helper: launch the jdk25u TP build from a Windows shell that has
# already loaded the VS 2022 x64 environment (vcvars64.bat).
#   cmd.exe ->  C:\cygwin64\bin\bash.exe scripts/98_run_build_jdk25.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/cygdrive/c/Program Files (x86)/Microsoft Visual Studio/Installer:$PATH"
export TP_BUILD_ROOT_CYG="${TP_BUILD_ROOT_CYG:-/cygdrive/c/j47build25}"

cd "$REPO_ROOT"
./scripts/06_build_tp_jdk25.sh "$REPO_ROOT/jdk25u"
