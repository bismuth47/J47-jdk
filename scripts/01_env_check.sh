#!/bin/bash
# J47 01: ビルド環境チェック + 依存関係導入 (MSYS2 UCRT64想定)
# 注意: OpenJDK公式はCygwin必須。MSYS2は非公式・失敗率が高い。量産はCygwin64推奨。
set -eux

VS_BAT_CAND1="/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat"
VS_BAT_CAND2="/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Auxiliary/Build/vcvars64.bat"
if [ ! -f "$VS_BAT_CAND1" ] && [ ! -f "$VS_BAT_CAND2" ]; then
  echo "ERROR: VS2022 vcvars64.bat not found"
  exit 1
fi

pacman -Sy --noconfirm --needed \
  base-devel autoconf make m4 unzip zip git python3 \
  mingw-w64-ucrt-x86_64-freetype \
  mingw-w64-ucrt-x86_64-alsa-lib \
  mingw-w64-ucrt-x86_64-cups

make --version
autoconf --version
git --version

BOOT_CANDIDATE="/c/tools/bootjdk-21"
if [ ! -x "$BOOT_CANDIDATE/bin/java.exe" ] && [ ! -x "$BOOT_CANDIDATE/bin/java" ]; then
  echo "ERROR: BootJDK 21+ not found at $BOOT_CANDIDATE"
  echo "Azul Zulu21等を $BOOT_CANDIDATE に展開してください"
  exit 1
fi
"$BOOT_CANDIDATE/bin/java" -version
echo "OK: env check passed"
