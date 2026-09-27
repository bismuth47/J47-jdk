> **⚠️ This document is superseded.**
> It is the original Japanese build log, kept for provenance. The canonical,
> current guide is the English [`../README.md`](../README.md), which reflects
> the post-`scripts/` directory layout, the corrected benchmark numbers, and the
> ergonomics crash fix. Paths quoted below use the *old* flat layout
> (`./02_configure.sh` instead of `./scripts/02_configure.sh`).

# J47 カスタムJDK (ZGC既定・低レイテンシ) ビルド手順

Azul Prime (C4/Falcon) の完全再現は不可。ZGC既定化による近似策。

## 手順

1. `01_env_check.sh` (MSYS2) + `01_env_check.ps1` (管理者PS) を実行
   - BootJDK21 (Zulu21等) を `C:\tools\bootjdk-21` に配置
   - `[Lock Pages in Memory]` 権限付与 + 再起動
2. JDK21ソース取得: `git clone https://github.com/openjdk/jdk21u`
3. パッチ適用済み (`jdk21u` に直接適用済み。原本は `patches/`):
   - `J47-lowlatency.patch` (ZGC既定 / AlwaysPreTouch / ForceTimeHighResolution / Windows large-page ログ)
   - `J47-throughput-2mb.patch` (ZGC条件付きJIT ergonomics。2026-09-27の起動クラッシュ修正を折込済み)
   - `J47-msvc1944-c2280.patch` (MSVC 19.44 の C2280 回避)
   - `J47-tp-ergo-fix.patch` (上記修正の差分記録のみ。修正は TP patch に折込済みのため単独適用しない)
   ```
   cd jdk21u && git diff --stat  # 6 files changed を確認
   # パッチ再現性の検証: .\verify_patches.ps1 (元ツリーへ順適用 → tree 一致を確認)
   # クリーンに戻す場合: git stash / 再適用は上の3パッチを順に git apply
   ```
4. `./02_configure.sh ./jdk21u`
   - 実績値: `--with-debug-level=release` + `--enable-jvm-feature-link-time-opt`
     (`--with-build-type` / `--enable-lto` はJDK21のconfigureで非対応のため修正済み)
   - Windows既知問題: vcvars抽出でSDK um/sharedパスが欠落し `LNK1104 kernel32.lib` になる
     → `02_configure.sh` 内 `--with-extra-cflags/ldflags` (umパス補完) で回避
5. `./05_build.sh ./jdk21u`
   - configure は `VS170COMNTOOLS` を見て MSVC を検出するため、**vcvars64.bat を読み込んだ
     環境**で Cygwin bash を起動する (`vcvars64.bat` が `VS170COMNTOOLS` を設定する):
     ```
     cmd /c "call ""C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"" >nul && C:\cygwin64\bin\bash.exe --login -c ""cd /cygdrive/c/Users/raiko/OneDrive/Desktop/J47 && ./05_build.sh ./jdk21u"""
     ```
     実績スクリプト: `run_build_tp2.cmd` (vcvars64 + 一時領域固定), 成功ログ: `tp_build3.log` (クラッシュ修正) / `tp_build4.log` (MaxVectorSize 修正)
6. `powershell -File 05_verify.ps1 C:\Users\raiko\OneDrive\Desktop\J47\jdk21u\build\windows-x86_64-server-release\images\jdk`

## 2026-09-27 追記: TPビルドの起動クラッシュ修正 (J47-tp-ergo-fix)

- 事象: `J47-throughput-2mb.patch` 適用ビルドで JVM 起動が必ず
  `EXCEPTION_INT_DIVIDE_BY_ZERO at GCArguments::compute_heap_alignment`
  (`gcArguments.cpp:82`) で落ち、`make images` が `java.desktop.jmod` 生成で失敗
  (`hs_err_pid16796.log` / `build/.../make-support/failure-summary.log`)。
- 原因: `os::init_before_ergo() -> os::large_page_init()` (`os.cpp:465-469`) は
  ergonomics より前に走り、`UseLargePages` が既定 false の間は即 return
  (`os_windows.cpp:3344-3347`) するため `os::large_page_size()` は 0 のまま。
  `Arguments::apply_ergo()` で `UseLargePages=true` を強制すると
  `lcm(0, alignment)` (`globalDefinitions.cpp:383-392`) がゼロ除算 → 全 JVM 起動が死亡。
- 併せて `UseCountedLoopSafepoints`/`LoopStripMiningIter` を ergonomic に強制すると
  `LoopStripMiningIterConstraintFunc` (`jvmFlagConstraintsCompiler.cpp:408-416`) が
  毎回警告を出し `LoopStripMiningIter` を 1 に書き換える (ZGC既定 1000 の逆効果)。
- 対策 (`patches/J47-tp-ergo-fix.patch`, 現在は `J47-throughput-2mb.patch` に折込済み):
  上記2グループに加え `MaxVectorSize=64` の ergonomic 強制も削除。
  - Large pages は per-run opt-in (`-XX:+UseLargePages`, 要 SeLockMemoryPrivilege)
  - LoopStripMining は ZGC 既定 (UseCountedLoopSafepoints=true / LoopStripMiningIter=1000) のまま
  - `MaxVectorSize` は auto のまま (AVX2=32 / AVX-512=64)。強制すると AVX2 機で
    毎回 `MaxVectorSize must be at most 32 on this platform` 警告が出て 32 にクランプされる
- 実績: `tp_build3.log` = クラッシュ修正込みで `BUILD OK` (2026-09-27 17:42)、
  `05_verify.ps1` = VERIFY OK (UseZGC/ZGenerational/AlwaysPreTouch=true, ZGC起動ログ確認)。
  `MaxVectorSize` 修正(3)込みの再ビルドは `tp_build4.log`。
- 移設 (2026-09-27 18:12): ビルドツリーを `C:\j47build` へ移設 (OneDrive同期の影響を回避)。
  「ファイル移動 + 新規configure」方式 (junction不可: spec.gmk の埋込絶対パスのため。README 下部の注意参照)。
  新規ビルドは `tp_build_j47build.log` (out-of-source configure `tp_configure_j47build.log` →
  `make images` 成功)。移設後の継続ビルドは `run_build_j47build.cmd` (vcvars64 + SDK PATH +
  TMP/TEMP固定 + TP_BUILD_ROOT_CYG=/cygdrive/c/j47build)。`02_configure*.sh` / `05_build.sh` は
  `TP_BUILD_ROOT_CYG` 対応済み。
- 再パッケージ (2026-09-27 18:14-18:30, `C:\j47pkg\jdk` を中継):
  `J47-JDK-21.zip` (571件, jmods/demo/src.zip 除外、展開物の `-version` 起動確認済み) /
  `J47-JDK-21-setup.exe` (NSIS, `/DJDKROOT=C:\j47pkg\jdk` でビルド、インストール/アンインストール動作を検証済み) /
  `J47-JDK-21.msi` (WiX heat→candle→light, `-JdkRoot` 対応。msiexec /a 展開検証済み)。
- MSI 階層修正 (2026-09-27 18:30 完了):
  旧ビルドで発生していた「heat 収集により `C:\Program Files\J47\JDK-21\jdk\` と余計な `jdk\` ディレクトリがネストされる」問題を修正。
  `build_msi.ps1` で `-srd` (Suppress Root Directory) を指定し、かつ `$Src` が直下に `bin\java.exe` を持つルートを指すように安全装置を追加。
  これにより `C:\Program Files\J47\JDK-21\` の直下に `bin/`, `lib/`, `conf/`, `release` 等が正しくフラットに配置されることを `msiexec /a` にて確認・検証済み。
- 再現性検証: `verify_patches.ps1` が元ツリーへパッチを順適用し、作業ツリーと
  完全一致することを確認する (tree ハッシュ比較)。

## Windows ビルド環境の注意 (2026-09-27 実測)

- Cygwin bash を起動する前に **vcvars64.bat** を読み込む (`VS170COMNTOOLS` が未設定だと
  configure が VS を検出できない)。
- **OneDrive 配下でビルドすると極端に遅くなる / まれに `LNK1327: rc.exe の実行中にエラー`
  や make のハングが起きる**。実測: `support/interim-jmods/java.base.jmod` (357MB) の書き込みに
  15分以上かかった。対策はビルドツリーを OneDrive 外 `C:\j47build` へ移すこと。
  **junction は使えない** (spec.gmk に絶対パスが埋め込まれるため)。手順は「旧 `images` のみ
  `robocopy /MOVE` → 新規 out-of-source configure (`TP_BUILD_ROOT_CYG`) → `make images`
  のフルビルド」で実績あり (`tp_configure_j47build.log` / `tp_build_j47build.log`)。
- ハング時は `make.exe`/`bash.exe` が残るので、`Get-Process make,bash | Stop-Process -Force`
  で掃除してから再実行する。

## 注意

- 公式ビルド要件は Cygwin64。MSYS2は `configure` で失敗しやすい。
- MSVC PGO (`/GENPROFILE`) はconfigure非対応。LTO (`--enable-jvm-feature-link-time-opt`) のみ推奨。
- `ForceTimeHighResolution` 既定化 (旧 `timeBeginPeriod(1)` 直書き案は撤回。`os_windows.cpp:152` の既存分岐を利用)。
- GC既定の変更点は `arguments.cpp` ではなく `gc/shared/gcConfig.cpp:98` (`select_gc_ergonomically`)。
  JDK24+では `ZGenerational` が削除済みのため該当ハンクを外すこと。
