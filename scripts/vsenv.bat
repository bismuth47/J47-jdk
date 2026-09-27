@echo off
REM ============================================================================
REM  J47 - load the VS 2022 x64 environment into the current cmd.exe
REM
REM  Deliberately ASCII-only: cmd.exe decodes a batch file using the console
REM  code page, so non-ASCII text here renders as mojibake on any machine whose
REM  code page is not the author's.
REM
REM  Prefer scripts\run_build_tp2.cmd, which does this and hands over to Cygwin
REM  bash in one step. Use this file when you want the environment in an
REM  interactive shell instead:
REM      vsenv.bat
REM      C:\cygwin64\bin\bash.exe --login
REM
REM  Note: a batch file cannot persist environment changes into a parent shell.
REM  To use the environment from PowerShell, run:
REM      & cmd /k '"...\vcvars64.bat"'
REM ============================================================================
setlocal
for %%E in (
  "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
  "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
) do (
  if exist %%E (
    call "%%~E"
    if not errorlevel 1 (
      echo VS 2022 x64 environment loaded: %%~E
      exit /b 0
    )
  )
)
echo ERROR: vcvars64.bat not found, or it failed to initialise.
echo        Install "Desktop development with C++" from the VS 2022 installer.
exit /b 1
