; J47 JDK 21 installer (NSIS, per-user, no admin required)
Unicode True
Name "J47 JDK 21 (Generational ZGC)"
OutFile "J47-JDK-21-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\J47-JDK-21"
RequestExecutionLevel user
ShowInstDetails show

!ifndef JDKROOT
!define JDKROOT "jdk21u\build\windows-x86_64-server-release\images\jdk"
!endif

!include "LogicLib.nsh"

Section "J47 JDK 21" SecJDK
  SetOutPath "$INSTDIR"
  File /r "${JDKROOT}\*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  ; HKCU environment (no admin)
  WriteRegStr HKCU "Environment" "JAVA_HOME" "$INSTDIR"
  ReadRegStr $0 HKCU "Environment" "Path"
  ${If} $0 == ""
    WriteRegExpandStr HKCU "Environment" "Path" "$INSTDIR\bin"
  ${Else}
    WriteRegExpandStr HKCU "Environment" "Path" "$INSTDIR\bin;$0"
  ${EndIf}
  ; per-user uninstall entry
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\J47JDK" "DisplayName" "J47 JDK 21 (Generational ZGC)"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\J47JDK" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\J47JDK" "InstallLocation" "$INSTDIR"
  ; broadcast env change
  System::Call 'user32::SendMessageTimeout(i 0xffff, i 0x1a, i 0, t "Environment", i 0, i 5000, i .r0)'
SectionEnd

Section "Uninstall"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\J47JDK"
  DeleteRegValue HKCU "Environment" "JAVA_HOME"
  ReadRegStr $0 HKCU "Environment" "Path"
  ${If} $0 != ""
    Push $0
    Push "$INSTDIR\bin;"
    Call un.StrReplace
    Pop $0
    WriteRegExpandStr HKCU "Environment" "Path" $0
  ${EndIf}
  System::Call 'user32::SendMessageTimeout(i 0xffff, i 0x1a, i 0, t "Environment", i 0, i 5000, i .r0)'
SectionEnd

Function un.StrReplace
  Exch $R1 ; needle
  Exch
  Exch $R0 ; haystack
  Push $R2
  Push $R3
  StrLen $R3 $R1
  StrCpy $R2 ""
  loop:
    StrCpy $R3 $R0 $R3
    StrCmp $R3 $R1 found
    StrCpy $R3 $R0 1
    StrCpy $R2 "$R2$R3"
    StrCpy $R0 $R0 "" 1
    StrCmp $R0 "" done loop
  found:
    StrCpy $R0 $R0 "" $R3
    StrCpy $R2 "$R2$R0"
    StrCpy $R0 $R2
  done:
    StrCpy $R0 $R2
    Pop $R3
    Pop $R2
    Exch $R0
    Exch
    Pop $R1
FunctionEnd
