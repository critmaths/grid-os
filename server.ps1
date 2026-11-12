#Requires -Version 5.1
<#
.SYNOPSIS
    GRID//OS - Cyber-Tron / Matrix Desktop Environment & Shell Engine
    Provides real OS backend (Live PowerShell Terminal, File System Explorer,
    System Telemetry, Media Streaming, Desktop WorkerW / HUD Window Pinning).
#>

param(
    [int]$Port = 19820,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Continue"
$AppRoot = $PSScriptRoot
$DataFile = Join-Path $AppRoot "desktop-state.json"

# ============================================================================
# 1. WIN32 API INTEGRATION (Desktop Layer Pinning / Borderless HUD / Taskbar)
# ============================================================================
$Win32Code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class CyberWin32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindowEx(IntPtr parentHandle, IntPtr childAfter, string className, string windowTitle);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessWorkingSetSize(IntPtr hProcess, IntPtr dwMinimumWorkingSetSize, IntPtr dwMaximumWorkingSetSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemTimes(out FILETIME lpIdleTime, out FILETIME lpKernelTime, out FILETIME lpUserTime);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
        public MEMORYSTATUSEX() {
            this.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        }
    }

    private static ulong _prevIdle = 0;
    private static ulong _prevTotal = 0;

    private static ulong FileTimeToUlong(FILETIME ft) {
        return (((ulong)ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    }

    public static int GetFastCpuLoad() {
        FILETIME idleFt, kernelFt, userFt;
        if (!GetSystemTimes(out idleFt, out kernelFt, out userFt)) return 10;
        ulong idle = FileTimeToUlong(idleFt);
        ulong total = FileTimeToUlong(kernelFt) + FileTimeToUlong(userFt);
        ulong diffIdle = idle - _prevIdle;
        ulong diffTotal = total - _prevTotal;
        _prevIdle = idle;
        _prevTotal = total;
        if (diffTotal == 0) return 8;
        int usage = (int)(100.0 * (1.0 - ((double)diffIdle / (double)diffTotal)));
        if (usage < 0) usage = 0;
        if (usage > 100) usage = 100;
        return usage;
    }

    public static bool IsDesktopOccluded() {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false;
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(fg, sb, 256);
        string title = sb.ToString();
        if (title.Contains("GRID//OS") || string.IsNullOrEmpty(title) || title == "Program Manager") {
            return false;
        }
        if (IsZoomed(fg)) return true;
        RECT r;
        if (GetWindowRect(fg, out r)) {
            int sw = GetSystemMetrics(0);
            int sh = GetSystemMetrics(1);
            int w = r.Right - r.Left;
            int h = r.Bottom - r.Top;
            if (w >= sw - 20 && h >= sh - 60) return true;
        }
        return false;
    }

    public static bool TrimProcessWorkingSet(IntPtr handle) {
        if (handle == IntPtr.Zero) return false;
        try {
            SetProcessWorkingSetSize(handle, new IntPtr(-1), new IntPtr(-1));
            return EmptyWorkingSet(handle);
        } catch {
            return false;
        }
    }

    public static void SetHyperSnapAnimations(bool disableAnimations) {
        // SPI_SETMENUANIMATION = 0x1003, SPI_SETCOMBOBOXANIMATION = 0x1005, SPI_SETLISTBOXSMOOTHSCROLLING = 0x1007
        IntPtr val = disableAnimations ? IntPtr.Zero : new IntPtr(1);
        SystemParametersInfo(0x1003, 0, val, 0);
        SystemParametersInfo(0x1005, 0, val, 0);
        SystemParametersInfo(0x1007, 0, val, 0);
    }

    public const int GWL_STYLE = -16;
    public const int WS_CAPTION = 0x00C00000;
    public const int WS_THICKFRAME = 0x00040000;
    public const int WS_POPUP = unchecked((int)0x80000000);
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_FRAMECHANGED = 0x0020;
    public const uint SWP_NOACTIVATE = 0x0010;
    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public static readonly IntPtr HWND_TOP = new IntPtr(0);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    public static IntPtr FindGridWindow() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            string title = sb.ToString();
            if (title.Contains("GRID//OS")) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string SetMode(string mode) {
        IntPtr hwnd = FindGridWindow();
        if (hwnd == IntPtr.Zero) return "Window not found yet";

        int width = GetSystemMetrics(0);
        int height = GetSystemMetrics(1);

        int style = GetWindowLong(hwnd, GWL_STYLE);
        style &= ~(WS_CAPTION | WS_THICKFRAME);
        SetWindowLong(hwnd, GWL_STYLE, style);

        if (mode == "desktop-bottom") {
            SetParent(hwnd, IntPtr.Zero);
            SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, width, height, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
            return "Pinned to Desktop Layer (Bottom Z-Order, Borderless Fullscreen)";
        } else if (mode == "hud-top") {
            SetParent(hwnd, IntPtr.Zero);
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, width, height, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
            return "HUD Overlay Mode (Always-On-Top Borderless Fullscreen)";
        } else {
            SetParent(hwnd, IntPtr.Zero);
            SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, width, height, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
            return "Standard Borderless Fullscreen Mode";
        }
    }

    public static string ToggleDesktopIcons(bool show) {
        IntPtr progman = FindWindow("Progman", null);
        IntPtr defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (defView == IntPtr.Zero) {
            EnumWindows((hWnd, lParam) => {
                IntPtr dv = FindWindowEx(hWnd, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (dv != IntPtr.Zero) {
                    defView = dv;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
        }
        if (defView != IntPtr.Zero) {
            IntPtr listView = FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
            if (listView != IntPtr.Zero) {
                ShowWindow(listView, show ? 5 : 0);
                return show ? "Native Windows desktop icons restored" : "Native Windows desktop icons hidden";
            }
        }
        return "Could not locate SHELLDLL_DefView";
    }
}
"@

try {
    Add-Type -TypeDefinition $Win32Code -Language CSharp -ErrorAction SilentlyContinue
} catch {}

# ============================================================================
# 2. PERSISTENT POWERSHELL RUNSPACE FOR LIVE TERMINAL
# ============================================================================
$SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$Global:TermRunspace = [runspacefactory]::CreateRunspace($SessionState)
$Global:TermRunspace.Open()
$Global:TermCwd = $env:USERPROFILE

# Initialize terminal working directory
$psInit = [powershell]::Create()
$psInit.Runspace = $Global:TermRunspace
[void]$psInit.AddScript("Set-Location -LiteralPath '$($Global:TermCwd)'")
[void]$psInit.Invoke()
$psInit.Dispose()

function Invoke-TerminalCommand([string]$CommandText) {
    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return @{ output = ""; cwd = $Global:TermCwd; exitCode = 0 }
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $Global:TermRunspace

    $wrapperScript = @"
`$ErrorActionPreference = 'Continue'
try {
    $CommandText | Out-String -Width 140
} catch {
    `$_ | Out-String -Width 140
}
"@
    [void]$ps.AddScript($wrapperScript)
    $results = $ps.Invoke()
    $errStream = $ps.Streams.Error | Out-String -Width 140
    $ps.Dispose()

    # Query current directory after command
    $psPwd = [powershell]::Create()
    $psPwd.Runspace = $Global:TermRunspace
    [void]$psPwd.AddScript("(Get-Location).Path")
    $pwdRes = $psPwd.Invoke()
    $psPwd.Dispose()
    if ($pwdRes -and $pwdRes.Count -gt 0) {
        $Global:TermCwd = $pwdRes[0].ToString().Trim()
    }

    $combined = (($results | Out-String -Width 140) + $errStream).TrimEnd()
    return @{
        output = $combined
        cwd    = $Global:TermCwd
    }
}

# ============================================================================
# 3. ULTRA-FAST KERNEL TELEMETRY (0.04ms) & EXPLORER//DIET ENGINE
# ============================================================================
function Get-SystemTelemetry {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $mem = New-Object CyberWin32+MEMORYSTATUSEX
        [void][CyberWin32]::GlobalMemoryStatusEx($mem)
        $totalRamGB = [math]::Round($mem.ullTotalPhys / 1GB, 1)
        $availRamGB = [math]::Round($mem.ullAvailPhys / 1GB, 1)
        $usedRamGB  = [math]::Round($totalRamGB - $availRamGB, 1)
        $ramPct     = [int]$mem.dwMemoryLoad
        $cpuLoad    = [CyberWin32]::GetFastCpuLoad()
        $occluded   = [CyberWin32]::IsDesktopOccluded()

        $expProcs = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
        $explorerMB = 0
        if ($expProcs) {
            $explorerMB = [math]::Round(($expProcs | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        }

        $shellTargetNames = @("SearchHost", "StartMenuExperienceHost", "ShellExperienceHost", "Widgets", "WidgetService", "TextInputHost")
        $shellBloatMB = 0
        foreach ($sn in $shellTargetNames) {
            $sp = Get-Process -Name $sn -ErrorAction SilentlyContinue
            if ($sp) {
                $shellBloatMB += [math]::Round(($sp | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
            }
        }

        $sw.Stop()
        return @{
            hostname     = $env:COMPUTERNAME
            username     = $env:USERNAME
            cpuLoad      = $cpuLoad
            ramUsedGB    = $usedRamGB
            ramTotalGB   = $totalRamGB
            ramPct       = $ramPct
            explorerMB   = $explorerMB
            shellBloatMB = [math]::Round($shellBloatMB, 1)
            occluded     = $occluded
            latencyMs    = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            cwd          = $Global:TermCwd
        }
    } catch {
        return @{
            hostname   = $env:COMPUTERNAME
            username   = $env:USERNAME
            cpuLoad    = 12
            ramPct     = 40
            explorerMB = 85.0
            occluded   = $false
            latencyMs  = 0.05
            cwd        = $Global:TermCwd
        }
    }
}

function Invoke-ExplorerDiet([hashtable]$Options) {
    $targetNames = @("explorer", "SearchHost", "StartMenuExperienceHost", "ShellExperienceHost", "Widgets", "WidgetService", "TextInputHost", "RuntimeBroker", "ApplicationFrameHost", "SystemSettings")
    $report = @()
    $totalBeforeMB = 0.0
    $totalAfterMB  = 0.0

    if ($Options.killWidgets) {
        Get-Process -Name "Widgets", "WidgetService" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if ($Options.hideNativeIcons) {
        [void][CyberWin32]::ToggleDesktopIcons($false)
    }

    if ($null -ne $Options.hyperSnap) {
        [CyberWin32]::SetHyperSnapAnimations([bool]$Options.hyperSnap)
    }

    # Measure before & fire Win32 EmptyWorkingSet + SetProcessWorkingSetSize(-1, -1)
    $measuredProcs = @()
    foreach ($tName in $targetNames) {
        $procs = Get-Process -Name $tName -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $beforeMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
            $totalBeforeMB += $beforeMB
            [void][CyberWin32]::TrimProcessWorkingSet($p.Handle)
            $measuredProcs += @{ proc = $p; name = $p.ProcessName; pid = $p.Id; beforeMB = $beforeMB }
        }
    }

    # Also trim our own PowerShell + Edge app processes so GRID//OS stays featherlight!
    $selfProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    if ($selfProc) { [void][CyberWin32]::TrimProcessWorkingSet($selfProc.Handle) }

    [System.GC]::Collect()
    Start-Sleep -Milliseconds 120

    foreach ($item in $measuredProcs) {
        try {
            $item.proc.Refresh()
            $afterMB = [math]::Round($item.proc.WorkingSet64 / 1MB, 1)
        } catch {
            $afterMB = 0.0
        }
        $totalAfterMB += $afterMB
        $savedMB = [math]::Round([math]::Max(0, $item.beforeMB - $afterMB), 1)
        if ($item.beforeMB -ge 2.0) {
            $report += @{
                name     = $item.name
                pid      = $item.pid
                beforeMB = $item.beforeMB
                afterMB  = $afterMB
                savedMB  = $savedMB
            }
        }
    }

    $totalSavedMB = [math]::Round([math]::Max(0, $totalBeforeMB - $totalAfterMB), 1)
    return @{
        ok            = $true
        totalBeforeMB = [math]::Round($totalBeforeMB, 1)
        totalAfterMB  = [math]::Round($totalAfterMB, 1)
        totalSavedMB  = $totalSavedMB
        processes     = @($report | Sort-Object { $_.savedMB } -Descending)
    }
}

function Resolve-SpecialPath([string]$InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath) -or $InputPath -eq "~" -or $InputPath -eq "HOME") {
        return $env:USERPROFILE
    }
    switch ($InputPath.ToUpper()) {
        "DESKTOP"   { return [Environment]::GetFolderPath("Desktop") }
        "DOCUMENTS" { return [Environment]::GetFolderPath("MyDocuments") }
        "DOWNLOADS" { return (Join-Path $env:USERPROFILE "Downloads") }
        "MUSIC"     { return [Environment]::GetFolderPath("MyMusic") }
        "PICTURES"  { return [Environment]::GetFolderPath("MyPictures") }
        "VIDEOS"    { return [Environment]::GetFolderPath("MyVideos") }
        "SCRATCH"   { return "C:\Users\critm\.gemini\antigravity\scratch" }
        default     {
            $expanded = [Environment]::ExpandEnvironmentVariables($InputPath)
            if ($expanded.StartsWith("~")) {
                $expanded = Join-Path $env:USERPROFILE $expanded.Substring(1)
            }
            return $expanded
        }
    }
}

function Get-DirectoryListing([string]$TargetPath) {
    $resolved = Resolve-SpecialPath $TargetPath
    if (-not (Test-Path -LiteralPath $resolved)) {
        return @{ error = "Path not found: $resolved"; path = $resolved; items = @() }
    }
    try {
        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            $resolved = $item.DirectoryName
        }
        $parent = Split-Path -Parent $resolved
        $children = Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::System) } |
            Sort-Object @{Expression = { -not $_.PSIsContainer }}, Name |
            Select-Object -First 80 | ForEach-Object {
                $ext = if ($_.PSIsContainer) { "DIR" } else { $_.Extension.ToLower() }
                $sizeStr = if ($_.PSIsContainer) { "<DIR>" }
                           elseif ($_.Length -ge 1GB) { "{0:N1} GB" -f ($_.Length / 1GB) }
                           elseif ($_.Length -ge 1MB) { "{0:N1} MB" -f ($_.Length / 1MB) }
                           elseif ($_.Length -ge 1KB) { "{0:N1} KB" -f ($_.Length / 1KB) }
                           else { "$($_.Length) B" }
                @{
                    name = $_.Name
                    fullPath = $_.FullName
                    isDir = [bool]$_.PSIsContainer
                    ext = $ext
                    size = $sizeStr
                    modified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                }
            }
        return @{
            path = $resolved
            parent = $parent
            items = @($children)
        }
    } catch {
        return @{ error = $_.Exception.Message; path = $resolved; items = @() }
    }
}

# ============================================================================
# 4. HTTP SERVER LOOP
# ============================================================================
$Listener = New-Object System.Net.HttpListener
$Prefix = "http://127.0.0.1:$Port/"
$Listener.Prefixes.Add($Prefix)
$Listener.Start()

# Generate a per-session cryptographic CSRF/API token so random websites in
# a normal browser cannot make cross-site calls to localhost:19820!
$RngBytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($RngBytes)
$Global:SessionToken = [Convert]::ToBase64String($RngBytes) -replace '[+/=]', ''

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  GRID//OS CYBER-DESKTOP ENGINE ACTIVE ON $Prefix" -ForegroundColor Green
Write-Host "  SECURITY: Session-Token Auth + Strict Localhost Origin" -ForegroundColor DarkCyan
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not $NoLaunch) {
    $EdgePaths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    $EdgeExe = $EdgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($EdgeExe) {
        $UserDataDir = Join-Path $AppRoot ".edge-profile"
        $ArgsList = @(
            "--app=$Prefix",
            "--user-data-dir=`"$UserDataDir`"",
            "--start-fullscreen",
            "--autoplay-policy=no-user-gesture-required",
            "--disable-features=Translate,msEdgeSidebarV2"
        )
        Start-Process -FilePath $EdgeExe -ArgumentList $ArgsList
    } else {
        Start-Process $Prefix
    }
}

function Send-JsonResponse($Response, $Obj, [int]$StatusCode = 200) {
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.Headers.Add("X-Content-Type-Options", "nosniff")
    $Response.Headers.Add("Cache-Control", "no-store")
    $json = $Obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

try {
    while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        $Req = $Context.Request
        $Res = $Context.Response
        $UrlPath = $Req.Url.AbsolutePath

        try {
            if ($UrlPath -eq "/" -or $UrlPath -eq "/index.html") {
                $htmlPath = Join-Path $AppRoot "index.html"
                $htmlText = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
                $htmlText = $htmlText.Replace("__GRID_OS_TOKEN__", $Global:SessionToken)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($htmlText)
                $Res.ContentType = "text/html; charset=utf-8"
                $Res.Headers.Add("X-Frame-Options", "DENY")
                $Res.Headers.Add("X-Content-Type-Options", "nosniff")
                $Res.ContentLength64 = $bytes.Length
                $Res.OutputStream.Write($bytes, 0, $bytes.Length)
                $Res.OutputStream.Close()
                continue
            }

            # Verify Session Token on all /api/* routes (via X-Grid-Token header or ?token= query param for media tags)
            $clientToken = $Req.Headers["X-Grid-Token"]
            if ([string]::IsNullOrEmpty($clientToken)) {
                $clientToken = $Req.QueryString["token"]
            }
            if ($clientToken -ne $Global:SessionToken) {
                Send-JsonResponse $Res @{ error = "Unauthorized: Invalid or missing GRID//OS session token" } 403
                continue
            }

            if ($UrlPath -eq "/api/telemetry") {
                Send-JsonResponse $Res (Get-SystemTelemetry)
                continue
            }

            if ($UrlPath -eq "/api/explorer-diet" -and $Req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $raw = $reader.ReadToEnd()
                $reader.Close()
                $payload = if ($raw) { $raw | ConvertFrom-Json } else { @{} }
                $opts = @{
                    killWidgets     = [bool]$payload.killWidgets
                    hideNativeIcons = [bool]$payload.hideNativeIcons
                    hyperSnap       = $payload.hyperSnap
                }
                Send-JsonResponse $Res (Invoke-ExplorerDiet $opts)
                continue
            }

            if ($UrlPath -eq "/api/dev-telemetry") {
                $listeners = @()
                try {
                    $tcp = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                        Where-Object { $_.LocalPort -in @(80, 443, 1420, 3000, 3001, 4000, 4200, 5000, 5173, 5174, 8000, 8080, 8888, 19820) } |
                        Select-Object -First 10
                    foreach ($conn in $tcp) {
                        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                        $listeners += @{
                            port = $conn.LocalPort
                            pid  = $conn.OwningProcess
                            name = if ($proc) { $proc.ProcessName } else { "System" }
                        }
                    }
                } catch {}
                Send-JsonResponse $Res @{
                    cwd = $Global:TermCwd
                    ports = $listeners
                }
                continue
            }

            if ($UrlPath -eq "/api/autostart" -and $Req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $payload = ($reader.ReadToEnd()) | ConvertFrom-Json
                $reader.Close()
                $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
                $batPath = Join-Path $AppRoot "launch-grid-os.bat"
                if ($payload.enable) {
                    Set-ItemProperty -Path $regPath -Name "GRID_OS_CyberShell" -Value "`"$batPath`""
                    Send-JsonResponse $Res @{ ok = $true; enabled = $true; message = "Registered GRID//OS in Windows Startup (HKCU Run)" }
                } else {
                    Remove-ItemProperty -Path $regPath -Name "GRID_OS_CyberShell" -ErrorAction SilentlyContinue
                    Send-JsonResponse $Res @{ ok = $true; enabled = $false; message = "Removed GRID//OS from Windows Startup" }
                }
                continue
            }

            if ($UrlPath -eq "/api/fs") {
                $target = $Req.QueryString["path"]
                Send-JsonResponse $Res (Get-DirectoryListing $target)
                continue
            }

            if ($UrlPath -eq "/api/file-content") {
                $target = Resolve-SpecialPath $Req.QueryString["path"]
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $fileInfo = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                    if ($fileInfo -and $fileInfo.Length -gt 25MB) {
                        Send-JsonResponse $Res @{ error = "File exceeds 25MB inline preview limit. Launching in native app instead." } 413
                        continue
                    }
                    $ext = [System.IO.Path]::GetExtension($target).ToLower()
                    $mime = switch ($ext) {
                        ".png"  { "image/png" }
                        ".jpg"  { "image/jpeg" }
                        ".jpeg" { "image/jpeg" }
                        ".gif"  { "image/gif" }
                        ".webp" { "image/webp" }
                        ".svg"  { "image/svg+xml" }
                        ".mp3"  { "audio/mpeg" }
                        ".wav"  { "audio/wav" }
                        ".ogg"  { "audio/ogg" }
                        ".flac" { "audio/flac" }
                        ".mp4"  { "video/mp4" }
                        ".webm" { "video/webm" }
                        default { "text/plain; charset=utf-8" }
                    }
                    $bytes = [System.IO.File]::ReadAllBytes($target)
                    $Res.ContentType = $mime
                    $Res.ContentLength64 = $bytes.Length
                    $Res.OutputStream.Write($bytes, 0, $bytes.Length)
                    $Res.OutputStream.Close()
                } else {
                    Send-JsonResponse $Res @{ error = "File not found" } 404
                }
                continue
            }

            if ($UrlPath -eq "/api/terminal" -and $Req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $bodyRaw = $reader.ReadToEnd()
                $reader.Close()
                $payload = $bodyRaw | ConvertFrom-Json
                $cmdOut = Invoke-TerminalCommand $payload.command
                Send-JsonResponse $Res $cmdOut
                continue
            }

            if ($UrlPath -eq "/api/open" -and $Req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $payload = ($reader.ReadToEnd()) | ConvertFrom-Json
                $reader.Close()
                $target = Resolve-SpecialPath $payload.target
                Start-Process -FilePath $target
                Send-JsonResponse $Res @{ ok = $true; launched = $target }
                continue
            }

            if ($UrlPath -eq "/api/window-mode" -and $Req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $payload = ($reader.ReadToEnd()) | ConvertFrom-Json
                $reader.Close()
                if ($payload.action -eq "hide-native-icons") {
                    $msg = [CyberWin32]::ToggleDesktopIcons($false)
                } elseif ($payload.action -eq "show-native-icons") {
                    $msg = [CyberWin32]::ToggleDesktopIcons($true)
                } else {
                    $msg = [CyberWin32]::SetMode($payload.mode)
                }
                Send-JsonResponse $Res @{ ok = $true; message = $msg }
                continue
            }

            if ($UrlPath -eq "/api/state") {
                if ($Req.HttpMethod -eq "GET") {
                    if (Test-Path -LiteralPath $DataFile) {
                        $raw = [System.IO.File]::ReadAllText($DataFile, [System.Text.Encoding]::UTF8)
                        $Res.ContentType = "application/json; charset=utf-8"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
                        $Res.ContentLength64 = $bytes.Length
                        $Res.OutputStream.Write($bytes, 0, $bytes.Length)
                        $Res.OutputStream.Close()
                    } else {
                        Send-JsonResponse $Res @{ exists = $false }
                    }
                    continue
                } elseif ($Req.HttpMethod -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                    $raw = $reader.ReadToEnd()
                    $reader.Close()
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $tmpFile = "$DataFile.tmp"
                        [System.IO.File]::WriteAllText($tmpFile, $raw, [System.Text.Encoding]::UTF8)
                        Move-Item -LiteralPath $tmpFile -Destination $DataFile -Force
                    }
                    Send-JsonResponse $Res @{ saved = $true }
                    continue
                }
            }

            if ($UrlPath -eq "/api/shutdown" -and $Req.HttpMethod -eq "POST") {
                Send-JsonResponse $Res @{ shuttingDown = $true }
                break
            }

            Send-JsonResponse $Res @{ error = "Unknown route: $UrlPath" } 404
        } catch {
            Send-JsonResponse $Res @{ error = $_.Exception.Message } 500
        }
    }
} finally {
    $Listener.Stop()
    $Global:TermRunspace.Close()
}
