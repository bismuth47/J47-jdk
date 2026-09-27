#!/usr/bin/env bash
# =============================================================================
#  00_organize_repo.sh - Restructure the J47 workspace into a Git-ready build kit
#  (Bash / Cygwin / Git-Bash / MSYS2 equivalent of 00_organize_repo.ps1)
#
#  Usage:
#     ./00_organize_repo.sh                     # relocate (default)
#     MODE=copy ./00_organize_repo.sh           # duplicate, keep originals
#     DRY_RUN=1 ./00_organize_repo.sh           # show what would happen
#     INCLUDE_LEGACY=1 ./00_organize_repo.sh    # also park the scratch scripts
#
#  The script is IDEMPOTENT and never deletes anything: in `move` mode each
#  original is first copied into .j47-organize-backup/.
#
#  Heavy artefacts (jdk21u/, build/, out/, *.log, *.msi, *.exe, *.zip) are left
#  in place; .gitignore keeps them out of Git.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MODE="${MODE:-move}"
DRY_RUN="${DRY_RUN:-0}"
INCLUDE_LEGACY="${INCLUDE_LEGACY:-0}"
BACKUP="$ROOT/.j47-organize-backup"

cd "$ROOT"

# --------------------------------------------------------------- directories
DIRS=(patches scripts scripts/repo benchmarks docs bench installer tools/legacy-analysis)
for d in "${DIRS[@]}"; do
  if [ ! -d "$d" ]; then
    [ "$DRY_RUN" = "1" ] || mkdir -p "$d"
    printf '  [dir ] %s\n' "$d"
  fi
done

# ------------------------------------------------------------------ file map
# "src|dest" pairs. src and dest are relative to $ROOT.
MAP=(
  # build pipeline -> scripts/
  "00_run_all.ps1|scripts/00_run_all.ps1"
  "01_env_check.ps1|scripts/01_env_check.ps1"
  "01_env_check.sh|scripts/01_env_check.sh"
  "02_configure.sh|scripts/02_configure.sh"
  "02_configure_tp.sh|scripts/02_configure_tp.sh"
  "02_configure_tp_jdk25.sh|scripts/02_configure_tp_jdk25.sh"
  "05_build.sh|scripts/05_build.sh"
  "05_verify.ps1|scripts/05_verify.ps1"
  "06_bench.ps1|scripts/06_bench.ps1"
  "06_build_tp.sh|scripts/06_build_tp.sh"
  "06_build_tp_jdk25.sh|scripts/06_build_tp_jdk25.sh"
  "07_gc_log_analyze.py|scripts/07_gc_log_analyze.py"
  "08_perf_guide.md|scripts/08_perf_guide.md"
  "98_run_build_jdk25.sh|scripts/98_run_build_jdk25.sh"
  "verify_patches.ps1|scripts/verify_patches.ps1"
  "run_build_tp2.cmd|scripts/run_build_tp2.cmd"
  "run_build_j47build.cmd|scripts/run_build_j47build.cmd"
  "vsenv.bat|scripts/vsenv.bat"
  "vsenv.sh|scripts/vsenv.sh"
  "install.ps1|scripts/install.ps1"
  "admin_tasks.ps1|scripts/admin_tasks.ps1"
  "run_configure_j47build.cmd|scripts/run_configure_j47build.cmd"
  "msi/build_msi.ps1|scripts/build_msi.ps1"
  # aggregated results -> benchmarks/
  "gc_performance_analysis.csv|benchmarks/gc-performance-summary.csv"
  "out/bench-v2/summary.csv|benchmarks/bench-v2-gc-summary.csv"
  "out/bench-v2/result.txt|benchmarks/bench-v2-result.txt"
  "out/bench-v2/version.txt|benchmarks/bench-v2-version.txt"
  "out/bench-v2/flags.txt|benchmarks/bench-v2-flags.txt"
  "out/bench-v2/powerscheme.txt|benchmarks/bench-v2-powerscheme.txt"
  "ANALYSIS_SUMMARY.md|benchmarks/ANALYSIS_SUMMARY.md"
  "COMPREHENSIVE_PERFORMANCE_ANALYSIS.md|benchmarks/PERFORMANCE_ANALYSIS.md"
  # narrative -> docs/
  "BUILD_SUMMARY.md|docs/BUILD_SUMMARY.md"
  # workload + installer source
  "J47.nsi|installer/J47.nsi"
  "J47-JDK-21.wxs|installer/J47.wxs"
  "icon.png|installer/icon.png"
)

moved=0; skipped=0; missing=()
for pair in "${MAP[@]}"; do
  src="${pair%%|*}"; dst="${pair##*|}"
  if [ ! -e "$src" ]; then
    if [ -e "$dst" ]; then skipped=$((skipped+1)); continue; fi
    missing+=("$src"); continue
  fi
  printf '  %s  %s  ->  %s\n' "$(printf '%-4s' "${MODE^^}")" "$src" "$dst"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$(dirname "$dst")"
    if [ "$MODE" = "move" ]; then
      # Keep a pristine copy first, then relocate the original.
      mkdir -p "$BACKUP/$(dirname "$src")"
      cp -p "$src" "$BACKUP/$src"
      mv -f "$src" "$dst"
    else
      cp -p "$src" "$dst"
    fi
    # Post-condition: never report success unless the file really landed.
    [ -e "$dst" ] || { echo "organize failed: $src -> $dst (destination missing)" >&2; exit 1; }
  fi
  moved=$((moved+1))
done

# -------------------------------------------------------- optional: legacy
if [ "$INCLUDE_LEGACY" = "1" ]; then
  for f in analysis_final.py analyze_gc_logs.py build_plan.py \
           comprehensive_analysis.py final_analysis.py minimal_analysis.py \
           run_analysis.py simple_analysis.py; do
    [ -e "$f" ] || continue
    printf '  MOVE %s  ->  tools/legacy-analysis/%s\n' "$f" "$f"
    if [ "$DRY_RUN" != "1" ]; then
      mkdir -p "$BACKUP/legacy" "tools/legacy-analysis"
      cp -p "$f" "$BACKUP/legacy/$f"
      mv -f "$f" "tools/legacy-analysis/$f"
    fi
  done
fi

# ------------------------------------------------- normalise line endings (EOL)
# This kit is authored on Windows (CRLF default). Bash rejects `do\r`/`then\r`
# and `git apply` mis-parses CRLF hunks, so force LF on shell/patch/python files.
# PowerShell/cmd keep CRLF. .gitattributes enforces the same policy in Git.
eol_fixed=0
for d in patches scripts benchmarks docs bench installer; do
  [ -d "$d" ] || continue
  while IFS= read -r f; do
    grep -qU $'\r' "$f" 2>/dev/null || continue
    printf '  EOL   %s  -> LF\n' "$f"
    if [ "$DRY_RUN" != "1" ]; then
      tr -d '\r' < "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
    fi
    eol_fixed=$((eol_fixed+1))
  done < <(find "$d" -type f \( -name '*.sh' -o -name '*.patch' -o -name '*.py' \))
done
# root-level scripts only (never recurse: jdk21u/ is ~1.2 GB)
while IFS= read -r f; do
  grep -qU $'\r' "$f" 2>/dev/null || continue
  printf '  EOL   %s  -> LF\n' "$f"
  if [ "$DRY_RUN" != "1" ]; then
    tr -d '\r' < "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  fi
  eol_fixed=$((eol_fixed+1))
done < <(find . -maxdepth 1 -type f \( -name '*.sh' -o -name '*.patch' -o -name '*.py' \) | sed 's|^\./||')

# ------------------------------------------------------------------ summary
echo
echo "=== ORGANIZE SUMMARY ==="
echo "  relocated : $moved"
echo "  already ok: $skipped"
echo "  EOL->LF   : $eol_fixed"
if [ ${#missing[@]} -gt 0 ]; then
  echo "  NOT FOUND : ${#missing[@]}"
  printf '      - %s\n' "${missing[@]}"
fi
echo
echo "  patches/:"
for p in J47-lowlatency.patch J47-throughput-2mb.patch J47-msvc1944-c2280.patch; do
  if [ -e "patches/$p" ]; then
    printf '    [ok ] %-32s %s KiB\n' "$p" "$(( $(wc -c < "patches/$p") / 1024 ))"
  else
    printf '    [MISSING] %s\n' "$p"
  fi
done
[ "$MODE" = "move" ] && [ "$moved" -gt 0 ] && echo && echo "  originals backed up to: $BACKUP"
[ "$DRY_RUN" = "1" ] && echo "  (DRY RUN - nothing was written)"
echo
echo "  Next: ./10_git_init_commit.sh -Remote git@github.com:<you>/<repo>.git"
echo
