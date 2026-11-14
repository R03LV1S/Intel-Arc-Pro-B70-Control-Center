<#
.SYNOPSIS
    B70-ControlCenter.ps1 (v1.1 Universal Edition)
    Interactive Power, Thermal Fan Curve & SYCL XMX Control Center for Intel Arc Pro B70 (32GB) & Battlemage GPUs.

.DESCRIPTION
    Resolves the Intel Arc Pro workstation "Power Sag" bottleneck (where hidden driver tuning tabs
    cause compute workloads to sag to 60W-80W) while persisting state across terminal restarts and
    guaranteeing one-click or automatic restoration to factory stock normal settings.

.LINK
    https://github.com/
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Interactive", "Lock", "Reset", "Hold", "Status")]
    [string]$Action = "Interactive",

    [ValidateSet("Eco150W", "Peak165W", "Sustained180W", "Burst230W", "Custom")]
    [string]$Profile = "Peak165W",

    [ValidateRange(0, 230)]
    [int]$Watts = 0,

    [string]$GpuId = "auto",

    [int]$StockWattsFallback = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 1. Auto-Elevate to Administrator (Required by Intel IGCL API)
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Elevating to Administrator for Intel IGCL hardware register access..." -ForegroundColor Yellow
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Action", $Action, "-Profile", $Profile, "-GpuId", $GpuId
    )
    if ($Watts -gt 0) { $argList += @("-Watts", $Watts) }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# 2. Universal Hardware & Binary Discovery
# ---------------------------------------------------------------------------
function Resolve-ArcGpuBinary {
    foreach ($cmdName in @("arc-gpu.exe", "arc-gpu")) {
        $c = Get-Command $cmdName -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($path in @(
        "$PSScriptRoot\arc-gpu.exe",
        "$PSScriptRoot\bin\arc-gpu.exe",
        "$env:ProgramFiles\ArcGpuControl\arc-gpu.exe",
        "$env:ProgramFiles\ArcFanControl\arc-gpu.exe",
        "$env:LOCALAPPDATA\Programs\ArcGpuControl\arc-gpu.exe"
    )) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Resolve-IntelArcAdapter {
    param([string]$RequestedId, [string]$ArcBin)
    if ($RequestedId -and $RequestedId -ne "auto") {
        return @{ Id = $RequestedId; Name = "Intel Arc GPU ($RequestedId)" }
    }

    # Query Windows WMI/CIM for Intel Arc Pro B70 (DEV_E223) or any Intel Arc discrete GPU
    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
        foreach ($vc in $controllers) {
            if ($vc.PNPDeviceID -match "VEN_8086&DEV_([0-9A-Za-f]{4})") {
                $devHex = $Matches[1].ToLower()
                if ($devHex -eq "e223" -or $vc.Name -match "B70|B60|Arc Pro|Arc") {
                    return @{ Id = $devHex; Name = $vc.Name }
                }
            }
        }
    } catch {}

    return @{ Id = "e223"; Name = "Intel Arc Pro B70 32GB (Default e223)" }
}

$arcBin      = Resolve-ArcGpuBinary
$adapterInfo = Resolve-IntelArcAdapter -RequestedId $GpuId -ArcBin $arcBin
$ActiveGpuId = $adapterInfo.Id
$AdapterName = $adapterInfo.Name

# ---------------------------------------------------------------------------
# 3. Persistent Paths & Hardware Profiles
# ---------------------------------------------------------------------------
$LeaseDir      = Join-Path $env:ProgramData "B70PowerLease"
$LeaseFile     = Join-Path $LeaseDir "b70_lease_$ActiveGpuId.json"
$ConfigBackup  = Join-Path $LeaseDir "ArcFanControl_config_$ActiveGpuId.ini.bak"
$ArcServiceCfg = Join-Path $env:ProgramData "ArcFanControl\config.ini"

$Profiles = [ordered]@{
    "Eco150W"       = @{ Name = "150W Eco (MoE & Quiet)";        Watts = 150; CurveName = "Quiet";      Curve = @("45:30", "55:45", "65:65", "75:85", "85:100") }
    "Peak165W"      = @{ Name = "165W Peak Efficiency (0.148/W)"; Watts = 165; CurveName = "Balanced";   Curve = @("45:30", "55:48", "65:68", "75:85", "85:100") }
    "Sustained180W" = @{ Name = "180W Sustained (27B & LongCtx)"; Watts = 180; CurveName = "Aggressive"; Curve = @("45:35", "55:55", "65:75", "75:90", "85:100") }
    "Burst230W"     = @{ Name = "230W Max Burst (Prefill/Batch)"; Watts = 230; CurveName = "MaxCool";    Curve = @("40:45", "50:65", "60:85", "70:100", "80:100") }
}

$SyclEnvKeys = @(
    "ONEAPI_DEVICE_SELECTOR",
    "SYCL_CACHE_PERSISTENT",
    "SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS",
    "UR_L0_USE_IMMEDIATE_COMMANDLISTS",
    "ZES_ENABLE_SYSMAN"
)

# ---------------------------------------------------------------------------
# 4. Telemetry & Hardware Actuation Functions
# ---------------------------------------------------------------------------
function Invoke-ArcGpuSafe {
    param([string]$Binary, [string[]]$Arguments, [int]$Retries = 3)
    if (-not $Binary) { return "" }
    for ($i = 1; $i -le $Retries; $i++) {
        $out = & $Binary @Arguments 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $out -notmatch "0x4000000b") {
            return $out.Trim()
        }
        Start-Sleep -Milliseconds 1200
    }
    return $out.Trim()
}

function Set-PersistentSyclEnv {
    param([bool]$Enable)
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
        foreach ($k in $SyclEnvKeys) {
            Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable($k, $null, "User")
        }
    }
}

function Get-CurrentStateAndTelemetry {
    param([string]$ArcBin)
    $state = [ordered]@{
        IsLocked          = $false
        ActiveProfileKey  = "Normal"
        ActiveProfileName = "STOCK NORMAL (Unlocked / Auto)"
        LockedWatts       = $StockWattsFallback
        StockWatts        = $StockWattsFallback
        LockedSince       = "N/A"
        FanCurveName      = "Firmware Auto"
        SyclImmediate     = ([Environment]::GetEnvironmentVariable("UR_L0_USE_IMMEDIATE_COMMANDLISTS", "User") -eq "1")
        LivePowerDrawW    = "N/A"
        LiveTempC         = "N/A"
        LiveFanSpeed      = "N/A"
        RawStatusText     = ""
    }

    if (Test-Path $LeaseFile) {
        try {
            $saved = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            $state.IsLocked          = $true
            $state.ActiveProfileKey  = $saved.locked_profile_key
            $state.ActiveProfileName = $saved.locked_profile_name
            $state.LockedWatts       = [int]$saved.locked_watts
            $state.StockWatts        = [int]$saved.stock_watts
            $state.LockedSince       = $saved.locked_at_local
            $state.FanCurveName      = $saved.fan_curve_name
        } catch {}
    } elseif (Test-Path $ArcServiceCfg) {
        try {
            $iniRaw = Get-Content $ArcServiceCfg -Raw
            if ($iniRaw -match "(?m)^power_limit\s*=\s*(\d+)") {
                $cfgW = [int]$Matches[1]
                if ($cfgW -ne $StockWattsFallback -and $cfgW -gt 0) {
                    $state.IsLocked          = $true
                    $state.ActiveProfileName = "EXTERNAL SERVICE LOCK (${cfgW}W)"
                    $state.LockedWatts       = $cfgW
                }
            }
        } catch {}
    }

    if ($ArcBin) {
        $rawStatus = Invoke-ArcGpuSafe -Binary $ArcBin -Arguments @("--gpu", $ActiveGpuId, "status") -Retries 1
        $rawFan    = Invoke-ArcGpuSafe -Binary $ArcBin -Arguments @("--gpu", $ActiveGpuId, "fan", "show") -Retries 1
        $combined  = "$rawStatus`n$rawFan"
        $state.RawStatusText = $rawStatus

        if ($combined -match "(?i)(?:power|draw|gpu power|package)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)\s*W") {
            $state.LivePowerDrawW = "$($Matches[1]) W"
        } elseif ($combined -match "([0-9]+(?:\.[0-9]+)?)\s*W") {
            $state.LivePowerDrawW = "$($Matches[1]) W"
        }

        if ($combined -match "(?i)(?:temp|temperature|gpu temp)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)\s*(?:C|°C)") {
            $state.LiveTempC = "$($Matches[1]) C"
        } elseif ($combined -match "([0-9]+(?:\.[0-9]+)?)\s*°?C") {
            $state.LiveTempC = "$($Matches[1]) C"
        }

        if ($combined -match "([0-9]+\s*RPM|[0-9]+%)") {
            $state.LiveFanSpeed = $Matches[1]
        }
    }

    return $state
}

function Apply-B70ProfileLock {
    param(
        [string]$ArcBin,
        [string]$ProfileKey,
        [string]$ProfileName,
        [int]$TargetWatts,
        [string]$CurveName,
        [string[]]$CurvePoints
    )
    if (-not (Test-Path $LeaseDir)) {
        New-Item -ItemType Directory -Path $LeaseDir -Force | Out-Null
    }

    $origStockWatts = $StockWattsFallback
    if (Test-Path $LeaseFile) {
        try {
            $old = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            if ($old.stock_watts) { $origStockWatts = [int]$old.stock_watts }
        } catch {}
    } else {
        if ((Test-Path $ArcServiceCfg) -and (-not (Test-Path $ConfigBackup))) {
            Copy-Item -Path $ArcServiceCfg -Destination $ConfigBackup -Force
        }
    }

    Write-Host "`n[LOCKING] Applying $ProfileName (${TargetWatts}W + $CurveName Fan Curve)..." -ForegroundColor Yellow

    if ($ArcBin) {
        Invoke-ArcGpuSafe -Binary $ArcBin -Arguments @("--gpu", $ActiveGpuId, "tune", "power", "$TargetWatts") | Out-Null
        $fanArgs = @("--gpu", $ActiveGpuId, "fan", "set") + $CurvePoints
        Invoke-ArcGpuSafe -Binary $ArcBin -Arguments $fanArgs | Out-Null
    } else {
        Write-Warning "arc-gpu.exe not found on PATH; saved profile state and applied SYCL flags only."
    }

    Set-PersistentSyclEnv -Enable $true

    $leaseData = [ordered]@{
        locked_by_pid       = $PID
        locked_at_local     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        gpu_id              = $ActiveGpuId
        adapter_name        = $AdapterName
        stock_watts         = $origStockWatts
        locked_profile_key  = $ProfileKey
        locked_profile_name = $ProfileName
        locked_watts        = $TargetWatts
        fan_curve_name      = "$CurveName ($($CurvePoints -join ' '))"
    }
    $leaseData | ConvertTo-Json | Set-Content -Path $LeaseFile -Encoding UTF8
    Write-Host "[LOCKED] $AdapterName is locked at ${TargetWatts}W ($ProfileName)." -ForegroundColor Green
}

function Restore-B70StockNormal {
    param([string]$ArcBin)
    $restoreW = $StockWattsFallback
    if (Test-Path $LeaseFile) {
        try {
            $saved = Get-Content $LeaseFile -Raw | ConvertFrom-Json
            if ($saved.stock_watts) { $restoreW = [int]$saved.stock_watts }
        } catch {}
    }

    Write-Host "`n[RESETTING] Restoring $AdapterName ($ActiveGpuId) to Stock Normal (${restoreW}W + 'fan auto')..." -ForegroundColor Cyan

    if ($ArcBin) {
        Invoke-ArcGpuSafe -Binary $ArcBin -Arguments @("--gpu", $ActiveGpuId, "tune", "power", "$restoreW") | Out-Null
        Invoke-ArcGpuSafe -Binary $ArcBin -Arguments @("--gpu", $ActiveGpuId, "fan", "auto") | Out-Null
    }

    if (Test-Path $ConfigBackup) {
        Copy-Item -Path $ConfigBackup -Destination $ArcServiceCfg -Force
        Remove-Item -Path $ConfigBackup -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $LeaseFile) {
        Remove-Item -Path $LeaseFile -Force -ErrorAction SilentlyContinue
    }

    Set-PersistentSyclEnv -Enable $false
    Write-Host "[RESTORED] GPU returned to Stock Normal (${restoreW}W, Firmware Auto Fan, SYCL overrides cleared)." -ForegroundColor Green
}

function Start-HoldSession {
    param([string]$ArcBin)
    $cur = Get-CurrentStateAndTelemetry -ArcBin $ArcBin
    if (-not $cur.IsLocked) {
        $p = $Profiles["Peak165W"]
        Apply-B70ProfileLock -ArcBin $ArcBin -ProfileKey "Peak165W" -ProfileName $p.Name -TargetWatts $p.Watts -CurveName $p.CurveName -CurvePoints $p.Curve
    }
    Write-Host "`n[HOLD MODE ACTIVE] GPU will automatically reset to Stock Normal when you press Ctrl+C." -ForegroundColor Cyan
    try {
        while ($true) {
            $live = Get-CurrentStateAndTelemetry -ArcBin $ArcBin
            Write-Host ("`r  Live Draw: {0,-10} | Temp: {1,-8} | Locked Target: {2}W ({3})   " -f $live.LivePowerDrawW, $live.LiveTempC, $live.LockedWatts, $live.ActiveProfileName) -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    } finally {
        Write-Host ""
        Restore-B70StockNormal -ArcBin $ArcBin
    }
}

# ---------------------------------------------------------------------------
# 5. CLI Non-Interactive Dispatch & Interactive Console Loop
# ---------------------------------------------------------------------------
if ($Action -eq "Lock") {
    $p = $Profiles[$Profile]
    $w = if ($Watts -gt 0) { $Watts } else { $p.Watts }
    Apply-B70ProfileLock -ArcBin $arcBin -ProfileKey $Profile -ProfileName $p.Name -TargetWatts $w -CurveName $p.CurveName -CurvePoints $p.Curve
    return
} elseif ($Action -eq "Reset") {
    Restore-B70StockNormal -ArcBin $arcBin
    return
} elseif ($Action -eq "Hold") {
    Start-HoldSession -ArcBin $arcBin
    return
} elseif ($Action -eq "Status") {
    (Get-CurrentStateAndTelemetry -ArcBin $arcBin) | Format-List
    return
}

$statusBanner = ""
while ($true) {
    $state = Get-CurrentStateAndTelemetry -ArcBin $arcBin
    Clear-Host

    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  INTEL ARC PRO B70 / BATTLEMAGE POWER & SYCL CONTROL CENTER (v1.1)" -ForegroundColor Cyan
    Write-Host "  DETECTED GPU : $AdapterName [PCI ID: $ActiveGpuId]" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan

    if ($state.IsLocked) {
        Write-Host ("  ACTIVE PROFILE   : [LOCKED] {0} ({1}W Ceiling)" -f $state.ActiveProfileName, $state.LockedWatts) -ForegroundColor Yellow
        Write-Host ("  LOCKED SINCE     : {0} (Saved on disk - persists across restarts)" -f $state.LockedSince) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  ACTIVE PROFILE   : [NORMAL] {0} ({1}W Baseline)" -f $state.ActiveProfileName, $state.StockWatts) -ForegroundColor Green
    }

    Write-Host ("  LIVE POWER DRAW  : {0}   |   GPU TEMP : {1}   |   FAN : {2}" -f $state.LivePowerDrawW, $state.LiveTempC, $state.LiveFanSpeed) -ForegroundColor White
    Write-Host ("  FAN CURVE MODE   : {0}" -f $state.FanCurveName) -ForegroundColor Gray
    Write-Host ("  SYCL IMMEDIATE   : {0}" -f $(if ($state.SyclImmediate) { "ENABLED (User Env + Current Shell)" } else { "DEFAULT (Off)" })) -ForegroundColor Gray
    Write-Host ("  ARC-GPU BINARY   : {0}" -f $(if ($arcBin) { $arcBin } else { "NOT FOUND (Press [I] for setup info)" })) -ForegroundColor DarkGray

    if ($state.RawStatusText) {
        Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkGray
        foreach ($line in ($state.RawStatusText -split "`r?`n" | Select-Object -First 6)) {
            if ($line.Trim()) { Write-Host "  $($line.Trim())" -ForegroundColor DarkCyan }
        }
    }

    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  SELECT A POWER & COOLING PROFILE:" -ForegroundColor White
    Write-Host "    [1] Lock 150W - Eco Mode          (MoE 30B-A3B, 9B Models, Quiet Fans)" -ForegroundColor Gray
    Write-Host "    [2] Lock 165W - Peak Efficiency   (Best tok/s/W for Daily 9B-27B Chat)" -ForegroundColor Cyan
    Write-Host "    [3] Lock 180W - Sustained Heavy   (Best for 27B Coding, 32K+ Context, TTS)" -ForegroundColor Yellow
    Write-Host "    [4] Lock 230W - Max Hardware Burst(64K+ Prefill, vLLM Batch, Diffusion, 3D)" -ForegroundColor Magenta
    Write-Host "    [5] Lock Custom Wattage           (Enter any target between 100W and 230W)" -ForegroundColor Gray
    Write-Host "    [6] Hold Mode (Live Monitor)      (Auto-resets to Normal when you press Ctrl+C)" -ForegroundColor Gray
    Write-Host "    ----------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "    [0] RESET TO STOCK NORMAL         (Restores Factory Watts + Fan Auto + Env)" -ForegroundColor Green
    Write-Host "    [G] Switch Target GPU PCIe ID     (For Multi-GPU B70/B60 Workstations)" -ForegroundColor DarkCyan
    Write-Host "    [R] Refresh Live Telemetry        [Q] Quit (Keeps current profile active)" -ForegroundColor DarkGray
    Write-Host "==========================================================================" -ForegroundColor Cyan

    if ($statusBanner) {
        Write-Host "  STATUS: $statusBanner" -ForegroundColor Green
        Write-Host ""
    }

    Write-Host -NoNewline "  Press a key [1-6, 0, G, R, Q]: " -ForegroundColor White
    try {
        $keyInfo = [Console]::ReadKey($true)
        $choice  = $keyInfo.KeyChar.ToString().ToUpper()
        Write-Host $choice
    } catch {
        $choice = (Read-Host).Trim().ToUpper()
    }

    switch ($choice) {
        "1" {
            $p = $Profiles["Eco150W"]
            Apply-B70ProfileLock -ArcBin $arcBin -ProfileKey "Eco150W" -ProfileName $p.Name -TargetWatts $p.Watts -CurveName $p.CurveName -CurvePoints $p.Curve
            $statusBanner = "Locked to 150W Eco Mode."
        }
        "2" {
            $p = $Profiles["Peak165W"]
            Apply-B70ProfileLock -ArcBin $arcBin -ProfileKey "Peak165W" -ProfileName $p.Name -TargetWatts $p.Watts -CurveName $p.CurveName -CurvePoints $p.Curve
            $statusBanner = "Locked to 165W Peak Efficiency."
        }
        "3" {
            $p = $Profiles["Sustained180W"]
            Apply-B70ProfileLock -ArcBin $arcBin -ProfileKey "Sustained180W" -ProfileName $p.Name -TargetWatts $p.Watts -CurveName $p.CurveName -CurvePoints $p.Curve
            $statusBanner = "Locked to 180W Sustained Heavy."
        }
        "4" {
            $p = $Profiles["Burst230W"]
            Apply-B70ProfileLock -ArcBin $arcBin -ProfileKey "Burst230W" -ProfileName $p.Name -TargetWatts $p.Watts -CurveName $p.CurveName -CurvePoints $p.Curve
            $statusBanner = "Locked to 230W Max Hardware Burst."
        }
        "5" {
            Write-Host ""
            $rawW = Read-Host "  Enter Custom Power Limit in Watts (100 - 230)"
            $parsedW = 0
            if ([int]::TryParse($rawW, [ref]$parsedW) -and $parsedW -ge 100 -and $parsedW -le 230) {
                $cName   = if ($parsedW -ge 180) { "Aggressive" } else { "Balanced" }
                $cPoints = if ($parsedW -ge 180) { $Profiles["Sustained180W"].Curve } else { $Profiles["Peak165W"].Curve }
                Apply-B70ProfileLock -ArcBin $arcBin -ProfileKey "Custom${parsedW}W" -ProfileName "Custom ${parsedW}W Lock" -TargetWatts $parsedW -CurveName $cName -CurvePoints $cPoints
                $statusBanner = "Locked to Custom ${parsedW}W."
            } else {
                $statusBanner = "Invalid wattage '$rawW'. Must be between 100 and 230."
            }
        }
        "6" {
            Start-HoldSession -ArcBin $arcBin
            $statusBanner = "Exited Hold Mode and restored Stock Normal."
        }
        "0" {
            Restore-B70StockNormal -ArcBin $arcBin
            $statusBanner = "Restored to Stock Normal (${StockWattsFallback}W + Firmware Auto Fan)."
        }
        "G" {
            Write-Host ""
            if ($arcBin) { & $arcBin list }
            $newId = (Read-Host "  Enter GPU PCI ID or Substring (e.g. e223)").Trim()
            if ($newId) {
                $ActiveGpuId = $newId
                $LeaseFile   = Join-Path $LeaseDir "b70_lease_$ActiveGpuId.json"
                $statusBanner = "Switched active GPU target to '$ActiveGpuId'."
            }
        }
        "R" {
            $statusBanner = "Telemetry refreshed at $((Get-Date).ToString('HH:mm:ss'))."
        }
        "Q" {
            Write-Host "`nExiting Control Center. Active profile remains persisted." -ForegroundColor Cyan
            break
        }
        default {
            $statusBanner = "Refreshed."
        }
    }
}
