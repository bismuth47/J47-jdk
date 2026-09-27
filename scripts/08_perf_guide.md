# J47 パフォーマンス診断ガイド (Generational ZGC / Windows)

対象: `06_bench.ps1` で取得した `bench.jfr` + `gc.log(+safepoint.log, jit.log)`。
前提: J47は Generational ZGC既定 (`UseZGC=true, ZGenerational=true`)。Azul Prime (C4/Falcon) の完全再現は不可であり、
本ガイドは「ZGC+C2でPrime相当の低レイテンシに寄せる」ための実務チェックリスト。

## 0. 前提コマンド

```powershell
# GCサマリ
python 07_gc_log_analyze.py --log "out\bench-*\gc.log*"
# JFRイベント一覧 (カスタムJDK同梱のjfrツール)
& "$Jdk\bin\jfr.exe" summary bench.jfr
& "$Jdk\bin\jfr.exe" print --events jdk.GCPhasePause,jdk.GCPhaseConcurrent,jdk.SafepointBegin,jdk.SafepointEnd,jdk.Compilation,jdk.CompilerPhase bench.jfr
# 実行中ダンプ (別プロセス)
& "$Jdk\bin\jcmd.exe" <pid> JFR.dump name=J47Bench filename=live.jfr
& "$Jdk\bin\jcmd.exe" <pid> GC.heap_info
```

## 1. チェックリストA: SafePoint応答遅延 (PrimeのC4一時停止に相当するSTWの主因)

| # | 見るもの | 取得方法 | 異常目安 | 対処フラグ/設定 |
|---|----------|----------|----------|-----------------|
| A1 | Pause Phase p99/max | `07_gc_log_analyze.py` → `Pause Phase` | p99 > 1ms / max > 5ms | `-Xmx`拡大, `-XX:ConcGCThreads=<cores/4→/2へ増>`, `-XX:ZAllocationSpikeTolerance=5` (既定2。スパイク耐性) |
| A2 | Safepoint sync時間 | `safepoint.log` の `Time since last` / `Stopping threads took` | sync > 1ms頻発 | 長時間TTSPスレッド特定→`jdk.SafepointBegin` の `threadId`を`jfr print`で追跡。JNI critical section / `Thread.sleep`乱用を排除 |
| A3 | Allocation Stall | `Allocation Stall n回/total` | 1回でも要調査 | A1と同じ + `-XX:-ZProactive` を試す (先回りGCが裏目に出る場合のみ)。割り当てレート自体を下げる (benchの`--alloc-kb`で再現確認) |
| A4 | JFR `jdk.SafepointBegin duration` | `jfr print --events jdk.SafepointBegin` | duration p99 > 1ms | 同上。WindowsではDefenderリアルタイムスキャン・電源プラン(省電力)が典型原因→除外設定+`powercfg /setactive <HighPerf GUID>` |
| A5 | `safepoint=info` の `Application time` | `gc.log` grep `Application time` | アプリ時間が短くGCが頻発 | ヒープ不足。`-Xms=-Xmx`固定+`AlwaysPreTouch`(06既定)維持 |

ポイント: ZGCのPauseは `Pause Mark Start / Pause Mark End / Pause Relocate Start` の3点のみがSTW。
それ以外 (Concurrent Mark/Relocate) はSTWではない。Pauseが長いのにconcurrentが短い場合はGC自体ではなくスレッド合流遅延 (A2/A4)。

## 2. チェックリストB: C2コンパイルのボトルネック (PrimeのFalcon相当にはならないが緩和可)

| # | 見るもの | 取得方法 | 異常目安 | 対処フラグ/設定 |
|---|----------|----------|----------|-----------------|
| B1 | `jdk.Compilation` 失敗/逆最適化 | `jit.log` (空なら正常。失敗時のみ記録) + JFR `jdk.Compilation`/`jdk.Deoptimization` | `failed`多発 / warmup後も`deopt`継続 | `-Xlog:jit+compilation`で対象メソッド特定→`@Warmup`延長、起動直後の計測を捨てる (JMH `-wi`)。`-XX:ReservedCodeCacheSize=512M` |
| B2 | C2キュー詰まり | JFR `jdk.CompilerPhase` の `phase=EMIT_CODE`長時間 / `jit.log` の `COMPILE SKIPPED: out of code cache` | 上記メッセージ有 | CodeCache拡大 (上記) / `-XX:+SegmentedCodeCache`確認。TieredCompilation停止 (`-Xcomp`等)は逆効果のため使わない |
| B3 | コンパイラスレッド不足 | `flags.txt` の `CICompilerCount` vs CPU数 | CPU 16+で既定のまま頭打ち | `-XX:CICompilerCount=<cores/4程度>` を明示。ベンチとGCスレッドの競合時は `-XX:ConcGCThreads` との合計がコア数を超えないよう調整 |
| B4 | `DebugNonSafepoints` 未設定によるプロファイル欠測 | `flags.txt` | JFR `jdk.ExecutionSample` が粗い | 06既定の `-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints` を維持 (本番はオーバーヘッドに注意) |

注意: C2はFalconのような投機的最適化プロファイルを持たない。Prime比で「JITが遅い」は仕様差であり、
フラグで埋められるのは warmup運用とCodeCache枯渇回避まで。

## 3. チェックリストC: OSスレッドスケジューリングのズレ (Windows特有)

| # | 見るもの | 取得方法 | 異常目安 | 対処フラグ/設定 |
|---|----------|----------|----------|-----------------|
| C1 | 電源プラン | `powerscheme.txt` (06が出力) | 省電力/バランス | `powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c` (High Performance)。ノートPCは電源接続 |
| C2 | `jdk.OSInformation` / `jdk.CPULoad` | `jfr print --events jdk.CPULoad,jdk.SystemProcess` | CPU steal/high context switch、特定コア張り付き | `-XX:+UseNUMA` (マルチソケットのみ)、GCスレッド数調整。ベンチスレッド数を物理コア以内に (`-Threads`) |
| C3 | `jdk.ThreadPark` / `jdk.JavaMonitorEnter` 長時間 | `jfr print --events jdk.ThreadPark,jdk.JavaMonitorEnter` | park > 10ms頻発、monitor競合 | アプリ側ロック粒度見直し。`-XX:ThreadPriorityPolicy=1` は効果薄のため原則不要 |
| C4 | Large Pages未使用 | `flags.txt` `UseLargePages` + 起動ログ `Large page size` | `SeLockMemoryPrivilege`無効 | `01_env_check.ps1`で権限付与+再起動→`-XX:+UseLargePages -XX:+AlwaysPreTouch`。共有環境では断片化で逆に遅くなる場合あり→比較計測 |
| C5 | タイマ分解能 | J47は `ForceTimeHighResolution`既定 (旧timeBeginPeriod直書きは撤回) | `sleep(1ms)`が15.6ms刻み | 既定のまま。外部ツールで分解能を荒らす常駐ソフト (ブラウザの省電力等) を停止 |
| C6 | Defender/ウイルス対策 | 手動 | `MsMpEng` CPU高 | 対象ディレクトリ (`OutDir`, JDK, bench) をリアルタイムスキャン除外 |

## 4. 世代別 (Young/Old) の読み方

- `Cycle Young(Minor)`: 短時間・高頻度が正常。急に長時間化したら Old昇格圧 (`--live-mb`大) またはアロケーションレート過大。
- `Cycle Old(Major/Tenured)`: 低頻度・やや長時間が正常。高頻度ならヒープ不足かlive過多→`-Xmx`拡大か保持量削減。
- `Concurrent Mark >> Concurrent Relocate`: ヒープ走査律速→ヒープ縮小 or オブジェクトグラフ肥大 (liveCap見直し)。
- `Relocate >> Mark`: 断片化/メモリ帯域律速→LargePages・NUMA・電源設定 (C4/C6) を先に確認。

## 5. 最小の対処セット (まず試す順)

1. `-Xms=-Xmx` 固定 + `AlwaysPreTouch` (06既定。ページフォルト由来の初回遅延を排除)
2. ヒープを `liveSet×3` 以上に (Stallが出る間は+1G刻みで再計測)
3. `-XX:ConcGCThreads` を既定→+2ずつ増加 (上限 物理コア/2)。`07`のStallが0になる点で止める
4. Windows側: 高パフォーマンスプラン + Defender除外 (C1/C6)。効果が最大の場合が多い
5. `-XX:ZAllocationSpikeTolerance=5`, `-XX:+UseLargePages` (権限要) を各1変数ずつA/B計測
6. それでもPause p99 > 1msなら JFR SafepointBegin durationで犯人スレッド特定→アプリ側修正 (A2)

## 6. よくある誤診

- `gc.log`全体のwall時間 (Cycle時間) をポーズと混同する。STWはPause 3点のみ。
- `gc.log.0`等のローテート先を見落として「ログが出ない」と判断する。`--log "gc.log*"` でglobする。
- JMHなしの内製ベンチのwarmup不足を回帰と誤認する。最初の30秒は捨てるか `-wi` 相当の捨て期間を設ける。
- `UseLargePages` が常に速いと思い込む。断片化環境では起動失敗/遅延の原因になるためA/B必須。
