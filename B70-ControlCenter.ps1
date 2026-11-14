<#
.SYNOPSIS
    B70-ControlCenter.ps1 (v2.2 Universal Direct-Driver + Multi-Mode Auto-Pilot Edition)
    Zero-dependency interactive Power, SYCL & Dynamic Phase-Scaling Control Center
    for the Intel Arc Pro B70 32GB (PCI ID 8086:e223).
    Calls C:\Windows\System32\ze_loader.dll (Intel Level Zero Sysman) directly via C# P/Invoke.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Interactive", "Lock", "Reset", "AutoPilot", "BackgroundDaemon", "Status")]
    [string]$Action = "Interactive",

    [ValidateSet("Eco150W", "Peak165W", "Sustained180W", "Burst230W")]
    [string]$Profile = "Peak165W",

    [int]$Watts = 0,
    [int]$StockWattsFallback = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 1. Auto-Elevate to Administrator (Required by Intel Driver Sysman API)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevating to Administrator for direct Intel driver Sysman access..." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Action", $Action, "-Profile", $Profile)
    if ($Watts -gt 0) { $argList += @("-Watts", $Watts) }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs
    exit
}

$env:ZES_ENABLE_SYSMAN = "1"

# 2. Compile Inline C# P/Invoke Bridge to C:\Windows\System32\ze_loader.dll
if (-not ("IntelLevelZeroSysman" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class IntelLevelZeroSysman {
    private const string ZE_DLL = "ze_loader.dll";

    [StructLayout(LayoutKind.Sequential)]
    public struct zes_power_sustained_limit_t {
        public int enabled;
        public int power;     // milliwatts (e.g., 165000 = 165W)
        public int interval;  // averaging window in milliseconds
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct zes_power_burst_limit_t {
        public int enabled;
        public int power;     // milliwatts (e.g., 230000 = 230W)
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct zes_power_peak_limit_t {
        public int powerAC;   // milliwatts
        public int powerDC;   // milliwatts
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct zes_power_energy_counter_t {
        public ulong energy;    // microjoules
        public ulong timestamp; // microseconds
    }

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zeInit(uint flags);

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesInit(uint flags);

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zeDriverGet(ref uint pCount, IntPtr[] phDrivers);

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zeDeviceGet(IntPtr hDriver, ref uint pCount, IntPtr[] phDevices);

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesDeviceEnumPowerDomains(IntPtr hDevice, ref uint pCount, IntPtr[] phPower);

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesPowerGetLimits(
        IntPtr hPower,
        ref zes_power_sustained_limit_t pSustained,
        ref zes_power_burst_limit_t pBurst,
        ref zes_power_peak_limit_t pPeak
    );

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesPowerSetLimits(
        IntPtr hPower,
        ref zes_power_sustained_limit_t pSustained,
        ref zes_power_burst_limit_t pBurst,
        ref zes_power_peak_limit_t pPeak
    );

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesPowerGetEnergyCounter(IntPtr hPower, ref zes_power_energy_counter_t pEnergy);

    private static IntPtr _cachedPowerHandle = IntPtr.Zero;

    public static IntPtr GetPrimaryPowerHandle() {
        if (_cachedPowerHandle != IntPtr.Zero) return _cachedPowerHandle;
        zeInit(0);
        zesInit(0);
        uint drvCount = 0;
        if (zeDriverGet(ref drvCount, null) != 0 || drvCount == 0) return IntPtr.Zero;
        IntPtr[] drivers = new IntPtr[drvCount];
        zeDriverGet(ref drvCount, drivers);

        for (int d = 0; d < drvCount; d++) {
            uint devCount = 0;
            if (zeDeviceGet(drivers[d], ref devCount, null) != 0 || devCount == 0) continue;
            IntPtr[] devices = new IntPtr[devCount];
            zeDeviceGet(drivers[d], ref devCount, devices);

            for (int i = 0; i < devCount; i++) {
                uint pwrCount = 0;
                if (zesDeviceEnumPowerDomains(devices[i], ref pwrCount, null) == 0 && pwrCount > 0) {
                    IntPtr[] pwrHandles = new IntPtr[pwrCount];
                    zesDeviceEnumPowerDomains(devices[i], ref pwrCount, pwrHandles);
                    _cachedPowerHandle = pwrHandles[0];
                    return _cachedPowerHandle;
                }
            }
        }
        return IntPtr.Zero;
    }

    public static int GetSustainedWatts() {
        IntPtr hPower = GetPrimaryPowerHandle();
        if (hPower == IntPtr.Zero) return -1;
        var sus = new zes_power_sustained_limit_t();
        var bst = new zes_power_burst_limit_t();
        var pk  = new zes_power_peak_limit_t();
        if (zesPowerGetLimits(hPower, ref sus, ref bst, ref pk) == 0 && sus.power > 0) {
            return sus.power / 1000;
        }
        return -1;
    }

    public static bool SetDualPowerLimits(int pl1SustainedWatts, int pl2BurstWatts, int intervalMs = 10000) {
        IntPtr hPower = GetPrimaryPowerHandle();
        if (hPower == IntPtr.Zero) return false;
        var sus = new zes_power_sustained_limit_t();
        var bst = new zes_power_burst_limit_t();
        var pk  = new zes_power_peak_limit_t();
        zesPowerGetLimits(hPower, ref sus, ref bst, ref pk);

        sus.enabled  = 1;
        sus.power    = pl1SustainedWatts * 1000;
        sus.interval = intervalMs;
        bst.enabled  = 1;
        bst.power    = Math.Min(230000, Math.Max(pl1SustainedWatts, pl2BurstWatts) * 1000);

        return zesPowerSetLimits(hPower, ref sus, ref bst, ref pk) == 0;
    }

    public static double SampleLivePowerWatts(int sampleWindowMs = 150) {
        IntPtr hPower = GetPrimaryPowerHandle();
        if (hPower == IntPtr.Zero) return -1.0;
        var e1 = new zes_power_energy_counter_t();
        var e2 = new zes_power_energy_counter_t();
        if (zesPowerGetEnergyCounter(hPower, ref e1) != 0) return -1.0;
        System.Threading.Thread.Sleep(sampleWindowMs);
        if (zesPowerGetEnergyCounter(hPower, ref e2) != 0) return -1.0;

        ulong dEnergyUj = e2.energy - e1.energy;
        ulong dTimeUs   = e2.timestamp - e1.timestamp;
        if (dTimeUs == 0) return -1.0;
        return Math.Round((double)dEnergyUj / (double)dTimeUs, 1);
    }
}
"@
}

# 3. Persistent Paths & Profiles
$LeaseDir  = Join-Path $env:ProgramData "B70PowerLease"
$LeaseFile = Join-Path $LeaseDir "b70_direct_lease.json"

$Profiles = [ordered]@{
    "Eco150W"       = @{ Name = "150W Eco (MoE & Idle)";         PL1 = 150; PL2 = 185 }
    "Peak165W"      = @{ Name = "165W Peak Efficiency (Decode)"; PL1 = 165; PL2 = 210 }
    "Sustained180W" = @{ Name = "180W Sustained (Heavy Compute)";PL1 = 180; PL2 = 220 }
    "Burst230W"     = @{ Name = "230W Max Burst (Prefill/Batch)";PL1 = 230; PL2 = 230 }
}

function Set-PersistentSyclEnv([bool]$Enable) {
    $keys = @(
        "ONEAPI_DEVICE_SELECTOR",
        "SYCL_CACHE_PERSISTENT",
        "SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS",
        "UR_L0_USE_IMMEDIATE_COMMANDLISTS",
        "ZES_ENABLE_SYSMAN"
    )
    if ($Enable) {
        $map = @{
            "ONEAPI_DEVICE_SELECTOR"                        = "level_zero:0"
            "SYCL_CACHE_PERSISTENT"                         = "0"
            "SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS" = "1"
            "UR_L0_USE_IMMEDIATE_COMMANDLISTS"              = "1"
            "ZES_ENABLE_SYSMAN"                             = "1"
        }
        foreach ($kv in $map.GetEnumerator()) {
            Set-Item -Path "Env:\$($kv.Key)" -Value $kv.Value
            [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, "User")
        }
    } else {
        foreach ($k in $keys) {
            Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable($k, $null, "User")
        }
    }
}

function Stop-ExistingAutoPilotDaemon {
    if (Test-Path $LeaseFile) {
        try {
            $saved = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            if ($saved.PSObject.Properties["daemon_pid"] -and $saved.daemon_pid -gt 0 -and $saved.daemon_pid -ne $PID) {
                $proc = Get-Process -Id ([int]$saved.daemon_pid) -ErrorAction SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }
}

function Save-LeaseState {
    param(
        [string]$ProfileKey,
        [string]$ProfileName,
        [int]$PL1Watts,
        [int]$PL2Watts,
        [int]$DaemonPid = 0
    )
    if (-not (Test-Path $LeaseDir)) { New-Item -ItemType Directory -Path $LeaseDir -Force | Out-Null }

    $origStock = $StockWattsFallback
    if (Test-Path $LeaseFile) {
        try {
            $old = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            if ($old.stock_watts) { $origStock = [int]$old.stock_watts }
        } catch {}
    } else {
        $hwBase = [IntelLevelZeroSysman]::GetSustainedWatts()
        if ($hwBase -gt 0) { $origStock = $hwBase }
    }

    $lease = [ordered]@{
        locked_at_local     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        stock_watts         = $origStock
        locked_profile_key  = $ProfileKey
        locked_profile_name = $ProfileName
        locked_watts        = $PL1Watts
        locked_pl2_watts    = $PL2Watts
        daemon_pid          = $DaemonPid
    }
    $lease | ConvertTo-Json | Set-Content -Path $LeaseFile -Encoding UTF8
}

function Lock-B70Direct([string]$ProfileKey, [string]$ProfileName, [int]$PL1Watts, [int]$PL2Watts) {
    Stop-ExistingAutoPilotDaemon
    [IntelLevelZeroSysman]::SetDualPowerLimits($PL1Watts, $PL2Watts, 10000) | Out-Null
    Set-PersistentSyclEnv -Enable $true
    Save-LeaseState -ProfileKey $ProfileKey -ProfileName $ProfileName -PL1Watts $PL1Watts -PL2Watts $PL2Watts -DaemonPid 0
}

function Reset-B70Direct {
    Stop-ExistingAutoPilotDaemon
    $restoreW = $StockWattsFallback
    if (Test-Path $LeaseFile) {
        try {
            $saved = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            if ($saved.stock_watts) { $restoreW = [int]$saved.stock_watts }
        } catch {}
    }
    [IntelLevelZeroSysman]::SetDualPowerLimits($restoreW, ($restoreW + 30), 10000) | Out-Null
    if (Test-Path $LeaseFile) { Remove-Item -Path $LeaseFile -Force -ErrorAction SilentlyContinue }
    Set-PersistentSyclEnv -Enable $false
}

function Get-B70DirectState {
    $driverCeilingW = [IntelLevelZeroSysman]::GetSustainedWatts()
    $liveDrawW      = [IntelLevelZeroSysman]::SampleLivePowerWatts(120)

    $st = [ordered]@{
        IsLocked          = $false
        ActiveProfileName = "STOCK NORMAL (Unlocked / Auto)"
        LockedWatts       = if ($driverCeilingW -gt 0) { $driverCeilingW } else { $StockWattsFallback }
        LockedPL2Watts    = if ($driverCeilingW -gt 0) { $driverCeilingW + 30 } else { 180 }
        StockWatts        = $StockWattsFallback
        LockedSince       = "N/A"
        DaemonActive      = $false
        DaemonPid         = 0
        DriverCeilingW    = if ($driverCeilingW -gt 0) { "$driverCeilingW W" } else { "Driver N/A" }
        LivePowerDrawW    = if ($liveDrawW -ge 0) { "$liveDrawW W" } else { "N/A" }
        SyclImmediate     = ([Environment]::GetEnvironmentVariable("UR_L0_USE_IMMEDIATE_COMMANDLISTS", "User") -eq "1")
    }

    if (Test-Path $LeaseFile) {
        try {
            $saved = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            $st.IsLocked          = $true
            $st.ActiveProfileName = $saved.locked_profile_name
            $st.LockedWatts       = [int]$saved.locked_watts
            $st.LockedPL2Watts    = if ($saved.PSObject.Properties["locked_pl2_watts"]) { [int]$saved.locked_pl2_watts } else { [int]$saved.locked_watts }
            $st.StockWatts        = [int]$saved.stock_watts
            $st.LockedSince       = $saved.locked_at_local
            if ($saved.PSObject.Properties["daemon_pid"] -and $saved.daemon_pid -gt 0) {
                $p = Get-Process -Id ([int]$saved.daemon_pid) -ErrorAction SilentlyContinue
                if ($p) {
                    $st.DaemonActive = $true
                    $st.DaemonPid    = [int]$saved.daemon_pid
                }
            }
        } catch {}
    }
    return $st
}

# 4. Universal Telemetry Multi-Mode Auto-Pilot Engine (150W <-> 165W <-> 180W <-> 230W)
function Invoke-SmartAutoPilotLoop([bool]$QuietBackground = $false) {
    Set-PersistentSyclEnv -Enable $true
    $currentTier   = "Eco150W"
    $currentPL1    = 150
    $currentPL2    = 185
    $burstEntered  = [DateTime]::MinValue
    $cooldownUntil = [DateTime]::MinValue
    $highSamples   = 0
    $lowSamples    = 0
    $idleSamples   = 0

    [IntelLevelZeroSysman]::SetDualPowerLimits($currentPL1, $currentPL2, 8000) | Out-Null
    Save-LeaseState -ProfileKey "AutoPilot" -ProfileName "SMART AUTO-PILOT [150W Eco Standby]" -PL1Watts $currentPL1 -PL2Watts $currentPL2 -DaemonPid $PID

    try {
        while ($true) {
            # Exit cleanly if the user pressed [0] Reset and deleted the lease file
            if ($QuietBackground -and (-not (Test-Path $LeaseFile))) { break }

            $draw = [IntelLevelZeroSysman]::SampleLivePowerWatts(250)
            if ($draw -lt 0) {
                Start-Sleep -Seconds 1
                continue
            }

            $now     = [DateTime]::UtcNow
            $nextTier = $currentTier

            # State transitions based on real-time XMX compute vs GDDR6 memory-bound draw
            if ($currentTier -eq "Burst230W") {
                $burstSeconds = ($now - $burstEntered).TotalSeconds
                if ($burstSeconds -ge 90.0) {
                    # 90s thermal safety guardrail -> step down to 180W Sustained with 10s cooldown
                    $nextTier      = "Sustained180W"
                    $cooldownUntil = $now.AddSeconds(10)
                    $lowSamples    = 0
                } elseif ($draw -lt 178.0) {
                    # Prefill finished! Workload is now GDDR6 memory-bound token decode (<178W)
                    $lowSamples++
                    if ($lowSamples -ge 5) {
                        $nextTier   = "Peak165W"
                        $lowSamples = 0
                    }
                } else {
                    $lowSamples = 0
                }
            } else {
                # Check for compute-bound prefill / batch surge
                if ($draw -ge 156.0 -and $now -ge $cooldownUntil) {
                    $highSamples++
                    $idleSamples = 0
                    if ($highSamples -ge 2) {
                        $nextTier     = "Burst230W"
                        $burstEntered = $now
                        $highSamples  = 0
                    }
                } elseif ($draw -ge 135.0) {
                    $highSamples = 0
                    $idleSamples = 0
                    $nextTier    = "Sustained180W"
                } elseif ($draw -ge 36.0) {
                    # Active token decode or medium inference -> hold 165W Peak Efficiency
                    $highSamples = 0
                    $idleSamples = 0
                    $nextTier    = "Peak165W"
                } else {
                    # Idle (<36W) -> drop to 150W Eco after ~5 seconds
                    $highSamples = 0
                    $idleSamples++
                    if ($idleSamples -ge 15) {
                        $nextTier = "Eco150W"
                    }
                }
            }

            if ($nextTier -ne $currentTier) {
                $currentTier = $nextTier
                $pSpec       = $Profiles[$currentTier]
                $currentPL1  = $pSpec.PL1
                $currentPL2  = $pSpec.PL2
                [IntelLevelZeroSysman]::SetDualPowerLimits($currentPL1, $currentPL2, 8000) | Out-Null
                Save-LeaseState -ProfileKey "AutoPilot" -ProfileName "SMART AUTO-PILOT [$($pSpec.Name)]" -PL1Watts $currentPL1 -PL2Watts $currentPL2 -DaemonPid $PID
            }

            if (-not $QuietBackground) {
                $phaseLabel = switch ($currentTier) {
                    "Eco150W"       { "IDLE / STANDBY (150W PL1)" }
                    "Peak165W"      { "TOKEN DECODE LOCK (165W PL1 / 210W PL2)" }
                    "Sustained180W" { "HEAVY COMPUTE (180W PL1 / 220W PL2)" }
                    "Burst230W"     { "⚡ XMX PREFILL / BATCH BURST (230W MAX)" }
                }
                Write-Host ("`r  Live Draw: {0,6} W  |  Active Tier: {1,-42}" -f $draw.ToString("0.0"), $phaseLabel) -NoNewline -ForegroundColor Yellow
            }
        }
    } finally {
        if (-not $QuietBackground) {
            Write-Host "`n[AUTO-PILOT STOPPED] Restoring Stock Normal..." -ForegroundColor Cyan
            Reset-B70Direct
        }
    }
}

# 5. CLI Non-Interactive Dispatch
if ($Action -eq "Lock") {
    $p  = $Profiles[$Profile]
    $w1 = if ($Watts -gt 0) { $Watts } else { $p.PL1 }
    $w2 = [Math]::Min(230, $w1 + 25)
    Lock-B70Direct $Profile $p.Name $w1 $w2
    return
} elseif ($Action -eq "Reset") {
    Reset-B70Direct
    return
} elseif ($Action -eq "AutoPilot") {
    Write-Host "=== SMART MULTI-MODE AUTO-PILOT (150W <-> 165W <-> 180W <-> 230W) ===" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C at any time to stop and restore Stock Normal.`n" -ForegroundColor Gray
    Invoke-SmartAutoPilotLoop -QuietBackground $false
    return
} elseif ($Action -eq "BackgroundDaemon") {
    Invoke-SmartAutoPilotLoop -QuietBackground $true
    return
} elseif ($Action -eq "Status") {
    (Get-B70DirectState) | Format-List
    return
}

# 6. Interactive Menu Loop
$banner = ""
while ($true) {
    $st = Get-B70DirectState
    Clear-Host
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  INTEL ARC PRO B70 (32GB) DIRECT-DRIVER & AUTO-PILOT CONTROL CENTER (v2.2)" -ForegroundColor Cyan
    Write-Host "  DRIVER API : C:\Windows\System32\ze_loader.dll (Zero External Apps)" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan

    if ($st.DaemonActive) {
        Write-Host ("  ACTIVE PROFILE   : [AUTO-PILOT DAEMON PID {0}] {1}" -f $st.DaemonPid, $st.ActiveProfileName) -ForegroundColor Magenta
        Write-Host ("  CURRENT LIMITS   : PL1 = {0}W Sustained  |  PL2 = {1}W Burst (Dynamic)" -f $st.LockedWatts, $st.LockedPL2Watts) -ForegroundColor Yellow
    } elseif ($st.IsLocked) {
        Write-Host ("  ACTIVE PROFILE   : [STATIC LOCK] {0}" -f $st.ActiveProfileName) -ForegroundColor Yellow
        Write-Host ("  CURRENT LIMITS   : PL1 = {0}W Sustained  |  PL2 = {1}W Burst (Since {2})" -f $st.LockedWatts, $st.LockedPL2Watts, $st.LockedSince) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  ACTIVE PROFILE   : [NORMAL] {0} ({1}W Factory Baseline)" -f $st.ActiveProfileName, $st.StockWatts) -ForegroundColor Green
    }

    Write-Host ("  LIVE POWER DRAW  : {0}   |   DRIVER PL1 READBACK : {1}" -f $st.LivePowerDrawW, $st.DriverCeilingW) -ForegroundColor White
    Write-Host ("  SYCL IMMEDIATE   : {0}" -f $(if ($st.SyclImmediate) { "ENABLED (User Env + Current Shell)" } else { "DEFAULT (Off)" })) -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  STATIC LOCKS (With Hardware PL2 Burst Window):" -ForegroundColor White
    Write-Host "    [1] Lock 150W PL1 / 185W PL2 - Eco Mode          (MoE 30B-A3B & 9B Models)" -ForegroundColor Gray
    Write-Host "    [2] Lock 165W PL1 / 210W PL2 - Peak Efficiency   (Daily 9B-27B Chat)" -ForegroundColor Cyan
    Write-Host "    [3] Lock 180W PL1 / 220W PL2 - Sustained Heavy   (27B Coding & 32K+ Ctx)" -ForegroundColor Yellow
    Write-Host "    [4] Lock 230W PL1 / 230W PL2 - Max Hardware Burst(64K+ Prefill & Batching)" -ForegroundColor Magenta
    Write-Host "    [5] Lock Custom Wattage      - Manual PL1 Target (100W - 230W)" -ForegroundColor Gray
    Write-Host "  DYNAMIC MULTI-MODE AUTO-PILOT (150W <-> 165W <-> 180W <-> 230W):" -ForegroundColor White
    Write-Host "    [6] Run Smart Auto-Pilot (Live Console)          (Resets on Ctrl+C)" -ForegroundColor Green
    Write-Host "    [7] Start Background Auto-Pilot Daemon           (Runs after window closes!)" -ForegroundColor Green
    Write-Host "    ----------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "    [0] RESET TO STOCK NORMAL (Stops Daemon + Restores Factory Watts + Env)" -ForegroundColor Green
    Write-Host "    [R] Refresh Live Power Draw                      [Q] Quit Window" -ForegroundColor DarkGray
    Write-Host "==========================================================================" -ForegroundColor Cyan

    if ($banner) { Write-Host "  STATUS: $banner`n" -ForegroundColor Green }
    Write-Host -NoNewline "  Select [1-7, 0, R, Q]: " -ForegroundColor White
    $ch = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
    Write-Host $ch

    switch ($ch) {
        "1" { $p = $Profiles["Eco150W"];       Lock-B70Direct "Eco150W"       $p.Name $p.PL1 $p.PL2; $banner = "Locked 150W PL1 / 185W PL2." }
        "2" { $p = $Profiles["Peak165W"];      Lock-B70Direct "Peak165W"      $p.Name $p.PL1 $p.PL2; $banner = "Locked 165W PL1 / 210W PL2." }
        "3" { $p = $Profiles["Sustained180W"]; Lock-B70Direct "Sustained180W" $p.Name $p.PL1 $p.PL2; $banner = "Locked 180W PL1 / 220W PL2." }
        "4" { $p = $Profiles["Burst230W"];     Lock-B70Direct "Burst230W"     $p.Name $p.PL1 $p.PL2; $banner = "Locked 230W PL1 / 230W PL2." }
        "5" {
            $w = 0
            $raw = Read-Host "`n  Enter Custom Sustained PL1 Watts (100-230)"
            if ([int]::TryParse($raw, [ref]$w) -and $w -ge 100 -and $w -le 230) {
                $pl2 = [Math]::Min(230, $w + 25)
                Lock-B70Direct "Custom${w}W" "Custom ${w}W PL1 / ${pl2}W PL2" $w $pl2
                $banner = "Locked Custom ${w}W PL1 / ${pl2}W PL2."
            }
        }
        "6" {
            Stop-ExistingAutoPilotDaemon
            Write-Host "`n[SMART AUTO-PILOT] Monitoring live XMX prefill vs GDDR6 decode power..." -ForegroundColor Cyan
            Write-Host "Press Ctrl+C to exit Auto-Pilot and restore Stock Normal.`n" -ForegroundColor Gray
            Invoke-SmartAutoPilotLoop -QuietBackground $false
            $banner = "Exited Live Auto-Pilot and restored Stock Normal."
        }
        "7" {
            Stop-ExistingAutoPilotDaemon
            $bgArgs = @("-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Action", "BackgroundDaemon")
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $bgArgs -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 600
            $banner = "Started Background Auto-Pilot Daemon (PID $($proc.Id)). You can safely close this window!"
        }
        "0" { Reset-B70Direct; $banner = "Stopped any active daemon and restored Stock Normal." }
        "R" { $banner = "Sampled live energy counter at $((Get-Date).ToString('HH:mm:ss'))." }
        "Q" { break }
    }
}
