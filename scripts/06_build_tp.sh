#!/bin/bash
# J47 06_build_tp: one-shot "configure (TP flags) + make images".
# Run from a Cygwin bash started inside a shell where vcvars64.bat was loaded.
# usage: ./scripts/06_build_tp.sh [openjdk-source-dir]
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="${1:-$REPO_ROOT/jdk21u}"
cd "$REPO_ROOT"
./scripts/02_configure_tp.sh "$SRC_DIR"
NCPUS=$(nproc 2>/dev/null || echo 8)
if [ -n "${TP_BUILD_ROOT_CYG:-}" ]; then
  # configure dropped a SPEC-bearing Makefile directly in the build root, and
  # make/Init.gmk rejects CONF= together with SPEC=.
  cd "$TP_BUILD_ROOT_CYG"
  make images JOBS="$NCPUS" LOG=info
  ls -lh "images/jdk/bin/java.exe"
else
  cd "$SRC_DIR"
  make images JOBS="$NCPUS" LOG=info CONF=windows-x86_64-server-release
  ls -lh "build/windows-x86_64-server-release/images/jdk/bin/java.exe"
fi
echo "BUILD TP OK"
