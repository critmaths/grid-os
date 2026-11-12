@echo off
title Stop GRID//OS Cyber-Desktop
echo Shutting down GRID//OS processes...

:: 1. Terminate any running server on port 19820
for /f "tokens=5" %%a in ('netstat -aon ^| findstr ":19820" ^| findstr "LISTENING"') do (
    taskkill /F /PID %%a >nul 2>&1
)

:: 2. Close Edge running the GRID//OS app profile
taskkill /F /FI "WINDOWTITLE eq GRID//OS*" >nul 2>&1

:: 3. Restore native Windows desktop icons just in case they were hidden
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$code = @'
using System;
using System.Runtime.InteropServices;
public class Restorer {
    [DllImport(\"user32.dll\")] public static extern IntPtr FindWindow(string c, string t);
    [DllImport(\"user32.dll\")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr c, string cl, string t);
    [DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr h, int cmd);
    public static void Show() {
        IntPtr p = FindWindow(\"Progman\", null);
        IntPtr dv = FindWindowEx(p, IntPtr.Zero, \"SHELLDLL_DefView\", null);
        if (dv != IntPtr.Zero) {
            IntPtr lv = FindWindowEx(dv, IntPtr.Zero, \"SysListView32\", null);
            if (lv != IntPtr.Zero) ShowWindow(lv, 5);
        }
    }
}
'@; Add-Type $code; [Restorer]::Show()" >nul 2>&1

echo GRID//OS stopped. Native desktop restored.
timeout /t 2 >nul
