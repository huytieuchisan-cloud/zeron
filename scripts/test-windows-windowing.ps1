# Owned-process native windowing regression and synthetic DWM movement timing.
# This does NOT measure physical mouse-to-photon drag latency or change the desktop.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [ValidateSet('frosted', 'opaque')][string]$Surface = 'frosted',
    [ValidateRange(10, 240)][int]$Samples = 60,
    [string]$Label = 'candidate',
    [switch]$Capture
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required' }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('../target/windows-windowing-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path (Join-Path $root 'Zeron') -Force | Out-Null
@{ onboardingCompleted = $true; appearance = 'dark'; surface = $Surface; reduceMotion = 'on'; soundEnabled = $false; notificationsEnabled = $false } |
    ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath (Join-Path $root 'Zeron/ui-settings.json')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ZeronWindowing {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    public static ulong Message(IntPtr hwnd, uint message, ulong wparam, long lparam) {
        UIntPtr result;
        if (SendMessageTimeout(hwnd, message, new UIntPtr(wparam), new IntPtr(lparam), 2, 5000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Window message failed/timed out: " + message + " error=" + Marshal.GetLastWin32Error());
        return result.ToUInt64();
    }
    public static double[] MoveSamples(IntPtr hwnd, int count, bool resize) {
        var samples = new List<double>();
        Message(hwnd, 0x0231, 0, 0); // WM_ENTERSIZEMOVE: exercise real backend transition.
        try {
            for (int i=0; i<count; i++) {
                var clock=Stopwatch.StartNew();
                int dx=(i%20)*4;
                if (!SetWindowPos(hwnd, IntPtr.Zero, 80+dx, 80+dx/2, 1000+(resize?dx:0), 700+(resize?dx/2:0), 0x14))
                    throw new InvalidOperationException("SetWindowPos failed");
                int result=DwmFlush();
                if (result != 0) throw new InvalidOperationException("DwmFlush HRESULT="+result);
                samples.Add(clock.Elapsed.TotalMilliseconds);
            }
        } finally { Message(hwnd, 0x0232, 0, 0); } // WM_EXITSIZEMOVE: restore current material.
        return samples.ToArray();
    }
    public static ulong Hit(IntPtr hwnd, int x, int y) {
        // GPUI's non-client callback uses its latest mouse hit-test cache.
        // Prime it through the app's real client input handler; no desktop pointer move.
        Message(hwnd, 0x0200, 0, ((long)(ushort)y << 16) | (ushort)x);
        var point=new Point {X=x,Y=y};
        if (!ClientToScreen(hwnd, ref point)) throw new InvalidOperationException("ClientToScreen failed");
        long coordinates=((long)(ushort)point.Y << 16) | (ushort)point.X;
        return Message(hwnd, 0x0084, 0, coordinates);
    }
}
'@
$overrides = @{
    HOME = $root; USERPROFILE = $root
    LOCALAPPDATA = (Join-Path $root 'AppData/Local'); APPDATA = (Join-Path $root 'AppData/Roaming')
    ZERON_DATA_DIR = (Join-Path $root 'Zeron'); ZERON_IPC_PORT = '0'; ZERON_EMBED_ENGINE = '1'
    ZERON_EDGE_TOKEN = $null; ZERON_EDGE_URL = 'http://127.0.0.1:1'; ZERON_ORG_ID = $null
    ZERON_HARNESS = 'mock'; ZERON_DISABLE_SOUND = '1'; ZERON_DISABLE_NOTIFICATIONS = '1'
}
$saved = @{}
$process = $null
# Native messages and lParam use physical pixels; do not mix PowerShell's
# default DPI-virtualized rectangles with the target's per-monitor DPI.
$previousDpi = [ZeronWindowing]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
$result = [ordered]@{ label = $Label; surface = $Surface; executable = $Exe; sha256 = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash; syntheticOnly = $true }
try {
    foreach ($key in $overrides.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $overrides[$key], 'Process')
    }
    $stdout = Join-Path $root 'stdout.txt'; $stderr = Join-Path $root 'stderr.txt'
    $process = Start-Process -FilePath $Exe -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw 'App exited before boot' }
        if ($process.MainWindowHandle -ne 0 -and (Get-Content -LiteralPath $stdout -Raw) -match 'engine core assembled') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0 -or (Get-Content -LiteralPath $stdout -Raw) -notmatch 'engine core assembled') { throw 'Window/engine did not boot within 25s' }
    $hwnd = $process.MainWindowHandle
    [uint32]$owner = 0
    [void][ZeronWindowing]::GetWindowThreadProcessId($hwnd, [ref]$owner)
    if ($owner -ne $process.Id) { throw 'HWND does not belong to owned process' }
    $result.processId = $process.Id
    $result.dpi = [ZeronWindowing]::GetDpiForWindow($hwnd)
    Start-Sleep -Milliseconds 750 # bounded settling, not used to poll a background job.
    [void][ZeronWindowing]::Message($hwnd, 0x0112, 0xF030, 0) # SC_MAXIMIZE
    if (-not [ZeronWindowing]::IsZoomed($hwnd)) { throw 'Maximize failed' }
    [void][ZeronWindowing]::Message($hwnd, 0x0112, 0xF120, 0) # SC_RESTORE
    if ([ZeronWindowing]::IsZoomed($hwnd)) { throw 'Restore failed' }
    [void][ZeronWindowing]::Message($hwnd, 0x0112, 0xF020, 0) # SC_MINIMIZE
    if (-not [ZeronWindowing]::IsIconic($hwnd)) { throw 'Minimize failed' }
    [void][ZeronWindowing]::Message($hwnd, 0x0112, 0xF120, 0)
    if ([ZeronWindowing]::IsIconic($hwnd)) { throw 'Unminimize failed' }
    $result.nativeSystemCommands = 'passed'
    [void][ZeronWindowing]::SetWindowPos($hwnd, [IntPtr]::Zero, 80, 80, 1000, 700, 0x14)
    [void][ZeronWindowing]::DwmFlush()
    Start-Sleep -Milliseconds 250
    $rect = [ZeronWindowing+Rect]::new()
    if (-not [ZeronWindowing]::GetClientRect($hwnd, [ref]$rect)) { throw 'GetClientRect failed' }
    $scale = $result.dpi / 96.0
    $hits = @()
    foreach ($distance in @(90, 54, 18)) { $hits += [ZeronWindowing]::Hit($hwnd, [int]($rect.Right - $distance*$scale), [int](18*$scale)) }
    $result.captionHitTests = $hits
    if (($hits -join ',') -ne '8,9,20') { throw "Caption hit targets incorrect: $hits" }
    foreach ($resize in @($false, $true)) {
        $samplesMs = [ZeronWindowing]::MoveSamples($hwnd, $Samples, $resize)
        $sorted = @($samplesMs | Sort-Object)
        $name = if ($resize) { 'resize' } else { 'move' }
        $result[$name] = @{ samples = $samplesMs; medianMs = $sorted[[int][math]::Floor(($sorted.Count-1)*0.5)]; p95Ms = $sorted[[int][math]::Ceiling(($sorted.Count-1)*0.95)]; maxMs = $sorted[-1] }
    }
    if ($Capture) {
        # Reuse the bounded client-only capture helper; PrintWindow must not
        # run unbounded in the controller process if the target stops answering.
        $capturePath = Join-Path $root 'capture.png'
        $metadataPath = Join-Path $root 'capture.json'
        $captureProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', ('"' + (Join-Path $PSScriptRoot 'test-windows-capture-client.ps1') + '"'),
            '-WindowHandle', $hwnd.ToInt64(), '-ExpectedProcessId', $process.Id,
            '-OutputFile', ('"' + $capturePath + '"'), '-MetadataFile', ('"' + $metadataPath + '"')
        ) -RedirectStandardOutput (Join-Path $root 'capture.stdout.txt') -RedirectStandardError (Join-Path $root 'capture.stderr.txt')
        try {
            $null = $captureProcess.Handle
            if (-not $captureProcess.WaitForExit(15000)) { throw 'Client capture timed out after 15s' }
            if ($captureProcess.ExitCode -ne 0) { throw "Client capture failed: $($captureProcess.ExitCode)" }
            $result.capture = $capturePath
        } finally {
            $captureProcess.Refresh()
            if (-not $captureProcess.HasExited) { $captureProcess.Kill(); $captureProcess.WaitForExit() }
            $captureProcess.Dispose()
        }
    }
    $cpuStart = $process.TotalProcessorTime.TotalSeconds
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 2
    $process.Refresh()
    $result.idleCpuOneCorePercent = ($process.TotalProcessorTime.TotalSeconds-$cpuStart) / $clock.Elapsed.TotalSeconds * 100
    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) { throw 'Normal close failed' }
    $result.exitCode = $process.ExitCode
    if ($process.ExitCode -ne 0) { throw "Nonzero close exit: $($process.ExitCode)" }
    $result.status = 'passed-windowing; inspect diagnostics separately'
    Write-Output "PASS: native system commands, caption hit targets and synthetic movement; evidence: $root"
} catch {
    $result.status = 'failed'; $result.error = $_.Exception.Message
    Write-Output "FAIL: $($_.Exception.Message); evidence: $root"
    throw
} finally {
    $result | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $root 'measurements.json')
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    if ($previousDpi -ne [IntPtr]::Zero) { [void][ZeronWindowing]::SetThreadDpiAwarenessContext($previousDpi) }
}
