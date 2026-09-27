#!/bin/bash
# J47: Cygwin/MSYS2側でVS環境を取り込む (configure前に source すること)
# 使い方: source ../vsenv.sh
for cand in \
  "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat" \
  "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Auxiliary/Build/vcvars64.bat" \
  "/c/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat" \
  "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat"; do
  if [ -f "$cand" ]; then
    echo "VS found: $cand"
    echo "NOTE: Cygwin promptからは cmd.exe経由で vcvars64.bat を先に実行し、同じ環境変数でbashを起動せよ (vsdevcmd)。直接source不可。"
    echo "例: cmd /k \"$cand\" && C:\\cygwin64\\bin\\bash.exe --login"
    VS_FOUND=1
    break
  fi
done
if [ "${VS_FOUND:-0}" != "1" ]; then
  echo "ERROR: VS2022 vcvars64.bat not found. VS2022 BuildTools + Windows SDK 10.0.22621+ を導入せよ。"
  return 1 2>/dev/null || exit 1
fi
