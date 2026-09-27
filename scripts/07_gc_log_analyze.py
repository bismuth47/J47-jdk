#!/usr/bin/env python3
"""07_gc_log_analyze.py - Generational ZGC (JDK21) gc.log 分析.

抽出指標:
 - 平均/最大 GCポーズ時間 (Pause Phase)
 - Young(Minor) / Old(Major/Tenured) 世代ごとのサイクル時間
 - Concurrent Mark / Concurrent Relocate の所要時間
 - Allocation Stall の発生回数と総停止時間

使い方:
  python 07_gc_log_analyze.py --log out/bench-xxx/gc.log
  python 07_gc_log_analyze.py --log "out/bench-*/gc.log*" --csv summary.csv

対応: Unified Logging (time,uptime decorated) の ZGC JDK17-21。
存在しない行があっても欠測として報告し、ゼロ除算しない。
"""
import argparse, glob, re, statistics, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows chcp併用推奨 (chcp 65001)
except Exception:
    pass

# --- 正規表現 (JDK21 Generational ZGC Unified Logging 実測ベース)
#  Pause例: "GC(0) Y: Pause Mark Start (Major) 0.050ms" / "GC(0) O: Pause Mark End 0.019ms"
#  Cycle例: "GC(1) Minor Collection (High Usage) 1020M(100%)->436M(43%) 0.034s" (秒単位に注意)
#  世代prefix: "y:"=Minor内 / "Y:"=Major内Young / "O:"=Old
RE_PAUSE   = re.compile(r"Pause\s+(Mark Start|Mark End|Relocate Start)\s+.*?(\d+(?:\.\d+)?)\s*ms")
RE_GEN     = re.compile(r"GC\(\d+\)\s+([YOyo]):")
# Cycle例: "GC(1) Minor Collection (High Usage) 1020M(100%)->436M(43%) 0.034s"
#
# PERFORMANCE: the cycle pattern used to be
#     r"GC\((\d+)\)\s+(.*?)\s+.*?(\d+(?:\.\d+)?)\s*(ms|s)\s*$"
# Two adjacent lazy quantifiers ((.*?)\s+.*?) make the engine explore an
# exponential set of splits per line. On the 14 MB / 125k-line JDK 25 log that
# pushed a full analysis past 50 seconds; on a 6 MB log it was 2 seconds. Fix by
# anchoring on the LAST number on the line instead of searching for one:
#   ...            (.*) \s+ (\d+(?:\.\d+)?) \s* (ms|s) \s*$
# (.*) is greedy and still backtracks, but only over the tail of one line, which
# is linear in practice rather than combinatorial.
RE_CYCLE   = re.compile(r"GC\((\d+)\)\s+(.*)\s+(\d+(?:\.\d+)?)\s*(ms|s)\s*$")
# Concurrentは集計行のみ ("Concurrent Mark 8.163ms")。内訳行 ("Mark Roots/Follow/Free",
# "Relocate Remset FP") は除外するため \s+直結の厳密形にする
RE_MARK    = re.compile(r"Concurrent Mark\s+(\d+(?:\.\d+)?)\s*ms")
RE_RELOC   = re.compile(r"Concurrent Relocate\s+(\d+(?:\.\d+)?)\s*ms")
RE_STALL   = re.compile(r"Allocation Stall\s+\(.*?\)\s+(\d+(?:\.\d+)?)\s*ms")
RE_GC_ID   = re.compile(r"GC\((\d+)\)")
RE_YOUNG   = re.compile(r"Minor|Young", re.IGNORECASE)
RE_OLD     = re.compile(r"Major|Old|Tenured", re.IGNORECASE)

def pct(data, p):
    if not data: return float("nan")
    s = sorted(data)
    i = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
    return s[i]

def stat(name, vals, unit="ms"):
    if not vals:
        return f"{name:28s}: n=0 (no data)"
    return (f"{name:28s}: n={len(vals):5d} avg={statistics.mean(vals):9.3f}{unit} "
            f"p50={pct(vals,50):9.3f} p99={pct(vals,99):9.3f} max={max(vals):9.3f} total={sum(vals):12.3f}")

def classify_cycle(desc: str) -> str:
    if RE_YOUNG.search(desc): return "young"
    if RE_OLD.search(desc): return "old"
    return "other"

def analyze(paths):
    pauses, pause_y, pause_o = [], [], []
    young, old, other = [], [], []
    marks, marks_y, marks_o = [], [], []
    relocs, relocs_y, relocs_o = [], [], []
    stalls = []
    gc_ids = set()
    lines = 0
    for pat in paths:
        for f in sorted(glob.glob(pat)):
            try:
                fh = open(f, errors="replace")
            except OSError as e:
                print(f"[warn] cannot open {f}: {e}", file=sys.stderr)
                continue
            with fh:
                for line in fh:
                    lines += 1
                    m = RE_GC_ID.search(line)
                    if m: gc_ids.add(m.group(1))
                    gm = RE_GEN.search(line)
                    gen = gm.group(1).upper() if gm else ""  # Y or O (yはYに正規化)
                    mp = RE_PAUSE.search(line)
                    # 終了時サマリ表 ("Young Pause:" / "Old Pause:" + avg/max列) は除外
                    if mp and "Pause:" not in line:
                        v = float(mp.group(2))
                        pauses.append(v)
                        if gen == "Y": pause_y.append(v)
                        elif gen == "O": pause_o.append(v)
                    if "Concurrent Mark" in line:
                        mm = RE_MARK.search(line)
                        if mm:
                            v = float(mm.group(1))
                            marks.append(v)
                            if gen == "Y": marks_y.append(v)
                            elif gen == "O": marks_o.append(v)
                    if "Concurrent Relocate" in line:
                        mr = RE_RELOC.search(line)
                        if mr:
                            v = float(mr.group(1))
                            relocs.append(v)
                            if gen == "Y": relocs_y.append(v)
                            elif gen == "O": relocs_o.append(v)
                    if "Allocation Stall (" in line:
                        ms = RE_STALL.search(line)
                        if ms: stalls.append(float(ms.group(1)))
                    mc = RE_CYCLE.search(line)
                    # Cycle行は "GC(n) <desc> ... Nms/Ns" かつ Pause/Concurrent/Stallを含まないものに限定
                    if mc and "Pause" not in line and "Concurrent" not in line and "Stall" not in line:
                        desc = mc.group(2)
                        try: v = float(mc.group(3))
                        except ValueError: continue
                        if mc.group(4) == "s": v *= 1000.0  # "0.034s" -> ms
                        c = classify_cycle(desc)
                        if c == "young": young.append(v)
                        elif c == "old": old.append(v)
                        # Minor/Majorを含まない純粋な "Garbage Collection ..." 行のみ other扱い
                        elif "ollection" in desc: other.append(v)
    return {
        "files": paths, "lines": lines, "gc_count": len(gc_ids),
        "pauses": pauses, "pause_y": pause_y, "pause_o": pause_o,
        "young": young, "old": old, "other": other,
        "marks": marks, "marks_y": marks_y, "marks_o": marks_o,
        "relocs": relocs, "relocs_y": relocs_y, "relocs_o": relocs_o,
        "stalls": stalls,
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="gc.log path (glob可, 例: 'out/bench-*/gc.log*')")
    ap.add_argument("--csv", default="", help="サマリCSV出力先 (任意)")
    a = ap.parse_args()
    r = analyze([a.log])
    print("=" * 72)
    print(f"GC LOG SUMMARY  pattern={a.log}  lines={r['lines']}  GC cycles(id数)={r['gc_count']}")
    print("=" * 72)
    print(stat("Pause Phase (STW)", r["pauses"]))
    print(stat("  Pause Young (Y/y)", r["pause_y"]))
    print(stat("  Pause Old (O)", r["pause_o"]))
    print(stat("Cycle Young(Minor)", r["young"]))
    print(stat("Cycle Old(Major/Tenured)", r["old"]))
    if r["other"]:
        print(stat("Cycle other", r["other"]))
    print(stat("Concurrent Mark", r["marks"]))
    print(stat("  Mark Young", r["marks_y"]))
    print(stat("  Mark Old", r["marks_o"]))
    print(stat("Concurrent Relocate", r["relocs"]))
    print(stat("  Relocate Young", r["relocs_y"]))
    print(stat("  Relocate Old", r["relocs_o"]))
    print(stat("Allocation Stall", r["stalls"]))
    print("-" * 72)
    # 判定ヒント (Azul Prime相当の目安ではなくZGC実務値)
    p99 = pct(r["pauses"], 99) if r["pauses"] else float("nan")
    mx = max(r["pauses"]) if r["pauses"] else float("nan")
    nstall = len(r["stalls"])
    print("HINTS:")
    if r["pauses"]:
        print(f"  - Pause p99={p99:.3f}ms max={mx:.3f}ms (ZGC目標: p99 < 1ms。超過時はスレッド数/ヒープ不足かSafepoint遅延を疑う)")
    else:
        print("  - Pause行なし: -Xlog に gc+phases=debug が含まれているか確認")
    if nstall:
        print(f"  - Allocation Stall {nstall}回 total={sum(r['stalls']):.1f}ms → GCが追いついていない。Heap拡大 / ConcGCThreads増 / SpikeTolerance見直し (08_perf_guide.md参照)")
    else:
        print("  - Allocation Stall なし (良好。GCが割り当てに追従できている)")
    if not r["marks"] and not r["relocs"]:
        print("  - Concurrent Mark/Relocate行なし: gc* ログが取れているか確認 (filecountローテーションで旧ファイルに分散の可能性)")
    if r["lines"] == 0:
        print("  - 0行: --log のglobがファイルにマッチしていない")
    if a.csv:
        import csv
        def row(n, v):
            import statistics as st
            if not v: return [n, 0, "", "", "", ""]
            return [n, len(v), f"{st.mean(v):.4f}", f"{pct(v,99):.4f}", f"{max(v):.4f}", f"{sum(v):.4f}"]
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["metric", "n", "avg_ms", "p99_ms", "max_ms", "total_ms"])
            for n, v in [("pause", r["pauses"]), ("pause_young", r["pause_y"]), ("pause_old", r["pause_o"]),
                         ("cycle_young", r["young"]), ("cycle_old", r["old"]),
                         ("conc_mark", r["marks"]), ("conc_mark_young", r["marks_y"]), ("conc_mark_old", r["marks_o"]),
                         ("conc_reloc", r["relocs"]), ("conc_reloc_young", r["relocs_y"]), ("conc_reloc_old", r["relocs_o"]),
                         ("stall", r["stalls"])]:
                w.writerow(row(n, v))
        print(f"CSV written: {a.csv}")

if __name__ == "__main__":
    main()
