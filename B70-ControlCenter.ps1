<#
.SYNOPSIS
    B70-ControlCenter.ps1 (v2.0 Standalone Direct-Driver Edition)
    Zero-dependency interactive Power & SYCL Control Center for Intel Arc Pro B70 (32GB).
    Calls C:\Windows\System32\ze_loader.dll (Intel Level Zero Sysman API) directly via inline C# P/Invoke.
    No third-party binaries or external fan apps required.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Interactive", "Lock", "Reset", "Status")]
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

# 2. Enable Level Zero Sysman in Process Before Loading ze_loader.dll
$env:ZES_ENABLE_SYSMAN = "1"

# 3. Compile Inline C# P/Invoke Bridge to C:\Windows\System32\ze_loader.dll
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
        public int interval;  // milliseconds
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct zes_power_burst_limit_t {
        public int enabled;
        public int power;     // milliwatts
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

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesDeviceEnumFans(IntPtr hDevice, ref uint pCount, IntPtr[] phFan);

    [DllImport(ZE_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int zesFanSetDefaultMode(IntPtr hFan);

    public static IntPtr GetPrimaryPowerHandle() {
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
                    return pwrHandles[0];
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

    public static bool SetSustainedWatts(int targetWatts) {
        IntPtr hPower = GetPrimaryPowerHandle();
        if (hPower == IntPtr.Zero) return false;
        var sus = new zes_power_sustained_limit_t();
        var bst = new zes_power_burst_limit_t();
        var pk  = new zes_power_peak_limit_t();
        zesPowerGetLimits(hPower, ref sus, ref bst, ref pk);

        sus.enabled = 1;
        sus.power   = targetWatts * 1000; // Convert Watts -> milliwatts
        bst.enabled = 1;
        bst.power   = Math.Min(230000, (targetWatts + 20) * 1000);

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

# 4. Persistent Lease File & Profiles
$LeaseDir  = Join-Path $env:ProgramData "B70PowerLease"
$LeaseFile = Join-Path $LeaseDir "b70_direct_lease.json"

$Profiles = [ordered]@{
    "Eco150W"       = @{ Name = "150W Eco (MoE & Quiet)";        Watts = 150 }
    "Peak165W"      = @{ Name = "165W Peak Efficiency (0.148/W)"; Watts = 165 }
    "Sustained180W" = @{ Name = "180W Sustained (27B & LongCtx)"; Watts = 180 }
    "Burst230W"     = @{ Name = "230W Max Burst (Prefill/Batch)"; Watts = 230 }
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

function Get-B70DirectState {
    $driverCeilingW = [IntelLevelZeroSysman]::GetSustainedWatts()
    $liveDrawW      = [IntelLevelZeroSysman]::SampleLivePowerWatts(120)

    $st = [ordered]@{
        IsLocked          = $false
        ActiveProfileName = "STOCK NORMAL (Unlocked / Auto)"
        LockedWatts       = if ($driverCeilingW -gt 0) { $driverCeilingW } else { $StockWattsFallback }
        StockWatts        = $StockWattsFallback
        LockedSince       = "N/A"
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
            $st.StockWatts        = [int]$saved.stock_watts
            $st.LockedSince       = $saved.locked_at_local
        } catch {}
    }
    return $st
}

function Lock-B70Direct([string]$ProfileKey, [string]$ProfileName, [int]$TargetWatts) {
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

    $ok = [IntelLevelZeroSysman]::SetSustainedWatts($TargetWatts)
    Set-PersistentSyclEnv -Enable $true

    $lease = [ordered]@{
        locked_at_local     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        stock_watts         = $origStock
        locked_profile_key  = $ProfileKey
        locked_profile_name = $ProfileName
        locked_watts        = $TargetWatts
        driver_write_ok     = $ok
    }
    $lease | ConvertTo-Json | Set-Content -Path $LeaseFile -Encoding UTF8
}

function Reset-B70Direct {
    $restoreW = $StockWattsFallback
    if (Test-Path $LeaseFile) {
        try {
            $saved = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            if ($saved.stock_watts) { $restoreW = [int]$saved.stock_watts }
        } catch {}
    }
    [IntelLevelZeroSysman]::SetSustainedWatts($restoreW) | Out-Null
    if (Test-Path $LeaseFile) { Remove-Item -Path $LeaseFile -Force -ErrorAction SilentlyContinue }
    Set-PersistentSyclEnv -Enable $false
}

# 5. Interactive Menu Loop
$banner = ""
while ($true) {
    $st = Get-B70DirectState
    Clear-Host
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  INTEL ARC PRO B70 (32GB) DIRECT-DRIVER CONTROL CENTER (Zero-Dependency)" -ForegroundColor Cyan
    Write-Host "  DRIVER API : C:\Windows\System32\ze_loader.dll (Level Zero Sysman)" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan

    if ($st.IsLocked) {
        Write-Host ("  ACTIVE PROFILE   : [LOCKED] {0} ({1}W Target)" -f $st.ActiveProfileName, $st.LockedWatts) -ForegroundColor Yellow
        Write-Host ("  LOCKED SINCE     : {0} (Persists across window closes)" -f $st.LockedSince) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  ACTIVE PROFILE   : [NORMAL] {0} ({1}W Factory Baseline)" -f $st.ActiveProfileName, $st.StockWatts) -ForegroundColor Green
    }

    Write-Host ("  LIVE POWER DRAW  : {0}   |   DRIVER PL1 LIMIT : {1}" -f $st.LivePowerDrawW, $st.DriverCeilingW) -ForegroundColor White
    Write-Host ("  SYCL IMMEDIATE   : {0}" -f $(if ($st.SyclImmediate) { "ENABLED (User Env + Current Shell)" } else { "DEFAULT (Off)" })) -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "    [1] Lock 150W - Eco Mode          (MoE 30B-A3B & 9B Models)" -ForegroundColor Gray
    Write-Host "    [2] Lock 165W - Peak Efficiency   (Best tok/s/W for Daily 9B-27B Chat)" -ForegroundColor Cyan
    Write-Host "    [3] Lock 180W - Sustained Heavy   (Best for 27B Coding & 32K+ Context)" -ForegroundColor Yellow
    Write-Host "    [4] Lock 230W - Max Hardware Burst(64K+ Prefill, Batch, Diffusion, 3D)" -ForegroundColor Magenta
    Write-Host "    [5] Lock Custom Wattage           (Enter 100W - 230W)" -ForegroundColor Gray
    Write-Host "    [0] RESET TO STOCK NORMAL         (Restores Factory Watts + Clears Env)" -ForegroundColor Green
    Write-Host "    [R] Refresh Live Power Draw       [Q] Quit (Keeps profile active)" -ForegroundColor DarkGray
    Write-Host "==========================================================================" -ForegroundColor Cyan

    if ($banner) { Write-Host "  STATUS: $banner`n" -ForegroundColor Green }
    Write-Host -NoNewline "  Select [1-5, 0, R, Q]: " -ForegroundColor White
    $ch = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
    Write-Host $ch

    switch ($ch) {
        "1" { Lock-B70Direct "Eco150W"       $Profiles["Eco150W"].Name       150; $banner = "Locked 150W via ze_loader.dll." }
        "2" { Lock-B70Direct "Peak165W"      $Profiles["Peak165W"].Name      165; $banner = "Locked 165W via ze_loader.dll." }
        "3" { Lock-B70Direct "Sustained180W" $Profiles["Sustained180W"].Name 180; $banner = "Locked 180W via ze_loader.dll." }
        "4" { Lock-B70Direct "Burst230W"     $Profiles["Burst230W"].Name     230; $banner = "Locked 230W via ze_loader.dll." }
        "5" {
            $w = 0
            $raw = Read-Host "`n  Enter Custom Watts (100-230)"
            if ([int]::TryParse($raw, [ref]$w) -and $w -ge 100 -and $w -le 230) {
                Lock-B70Direct "Custom${w}W" "Custom ${w}W Lock" $w
                $banner = "Locked Custom ${w}W via ze_loader.dll."
            }
        }
        "0" { Reset-B70Direct; $banner = "Restored Stock Normal via ze_loader.dll." }
        "R" { $banner = "Sampled live energy counter at $((Get-Date).ToString('HH:mm:ss'))." }
        "Q" { break }
    }
}
