# ======================================================================
# Latency and Thermal Detailed Diagnostic Tool
# Mode    : Read-Only Audit
# Purpose : Analyze system latency indicators, driver activity, network
#           and disk latency, and CPU/GPU/storage thermal conditions.
# ======================================================================

$ErrorActionPreference = "SilentlyContinue"

# ======================================================================
# Initialization
# ======================================================================

$LatencyScore = 100
$ThermalScore = 100

$Issues = @()
$Warnings = @()
$HighLatencyDrivers = @()

# ======================================================================
# Administrator Status
# ======================================================================

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdministrator = $CurrentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

Write-Host ""
Write-Host "Administrator Status : " -NoNewline

if ($IsAdministrator) {
    Write-Host "YES" -ForegroundColor Green
}
else {
    Write-Host "NO" -ForegroundColor Yellow
    Write-Host "WARNING: Some diagnostic counters and hardware sensors may be unavailable without elevation." -ForegroundColor Yellow
}

# ======================================================================
# Temperature Conversion
# ======================================================================

function Convert-Temperature {
    param (
        [Parameter(Mandatory = $true)]
        [double]$Celsius
    )

    return [ordered]@{
        Celsius    = [math]::Round($Celsius, 2)
        Fahrenheit = [math]::Round(($Celsius * 9 / 5) + 32, 2)
        Kelvin     = [math]::Round($Celsius + 273.15, 2)
        Reaumur    = [math]::Round($Celsius * 0.8, 2)
        Rankine    = [math]::Round(($Celsius + 273.15) * 9 / 5, 2)
        Delisle    = [math]::Round((100 - $Celsius) * 1.5, 2)
        Newton     = [math]::Round($Celsius * 0.33, 2)
        Romer      = [math]::Round(($Celsius * 21 / 40) + 7.5, 2)
    }
}

function Write-TemperatureReport {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [double]$Celsius
    )

    $Temperature = Convert-Temperature -Celsius $Celsius

    Write-Host "$Label"
    Write-Host ("  Celsius    : {0:N2} °C" -f $Temperature.Celsius)
    Write-Host ("  Fahrenheit : {0:N2} °F" -f $Temperature.Fahrenheit)
    Write-Host ("  Kelvin     : {0:N2} K"  -f $Temperature.Kelvin)
    Write-Host ("  Réaumur    : {0:N2} °Ré" -f $Temperature.Reaumur)
    Write-Host ("  Rankine    : {0:N2} °Ra" -f $Temperature.Rankine)
    Write-Host ("  Delisle    : {0:N2} °De" -f $Temperature.Delisle)
    Write-Host ("  Newton     : {0:N2} °N" -f $Temperature.Newton)
    Write-Host ("  Rømer      : {0:N2} °Rø" -f $Temperature.Romer)

    return $Temperature
}

# ======================================================================
# CPU and System Latency Counters
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "CPU and System Latency"
Write-Host "======================================================================"

$InterruptPercent = $null
$DpcPercent = $null
$ContextSwitches = $null

try {
    $InterruptPercent = (
        Get-Counter "\Processor(_Total)\% Interrupt Time"
    ).CounterSamples[0].CookedValue

    $DpcPercent = (
        Get-Counter "\Processor(_Total)\% DPC Time"
    ).CounterSamples[0].CookedValue

    $ContextSwitches = (
        Get-Counter "\System\Context Switches/sec"
    ).CounterSamples[0].CookedValue

    Write-Host ("Current Interrupt Time : {0:N2} %" -f $InterruptPercent)
    Write-Host ("Current DPC Time       : {0:N2} %" -f $DpcPercent)
    Write-Host ("Context Switches/sec   : {0:N0}" -f $ContextSwitches)
}
catch {
    Write-Host "Performance counters are unavailable." -ForegroundColor Yellow
    $Warnings += "System performance counters are unavailable."
}

# ======================================================================
# Driver DPC and ISR Activity
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Driver DPC / ISR Activity"
Write-Host "======================================================================"

try {
    $DpcSamples = Get-Counter "\Interrupts(*)\DPCs Queued/sec"
    $IsrSamples = Get-Counter "\Interrupts(*)\ISRs/sec"

    $DriverActivity = @()

    foreach ($sample in $DpcSamples.CounterSamples) {

        $instance = $sample.InstanceName
        $dpcValue = $sample.CookedValue

        $matchingIsr = $IsrSamples.CounterSamples |
            Where-Object {
                $_.InstanceName -eq $instance
            } |
            Select-Object -First 1

        $isrValue = 0

        if ($matchingIsr) {
            $isrValue = $matchingIsr.CookedValue
        }

        $DriverActivity += [PSCustomObject]@{
            Driver = $instance
            DPC    = $dpcValue
            ISR    = $isrValue
        }
    }

    if ($DriverActivity.Count -eq 0) {
        Write-Host "No per-driver DPC/ISR activity was returned."
    }
    else {

        foreach ($driver in $DriverActivity) {

            if (($driver.DPC -ge 1000) -or ($driver.ISR -ge 1000)) {

                $HighLatencyDrivers += [PSCustomObject]@{
                    Driver = $driver.Driver
                    DPC    = [math]::Round($driver.DPC, 2)
                    ISR    = [math]::Round($driver.ISR, 2)
                }
            }
        }

        if ($HighLatencyDrivers.Count -eq 0) {
            Write-Host "No common high-latency driver patterns detected."
        }
        else {

            Write-Host "Potential high-latency driver activity detected:" -ForegroundColor Yellow

            foreach ($driver in $HighLatencyDrivers) {
                Write-Host (
                    "  {0} | DPC: {1:N2}/sec | ISR: {2:N2}/sec" -f
                    $driver.Driver,
                    $driver.DPC,
                    $driver.ISR
                )
            }

            $LatencyScore -= 15
            $Warnings += "Potentially elevated driver DPC/ISR activity detected."
        }
    }
}
catch {
    Write-Host "Per-driver DPC/ISR counters are unavailable."
    $Warnings += "Per-driver DPC/ISR counters are unavailable on this system."
}

# ======================================================================
# Disk Latency
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Disk Latency"
Write-Host "======================================================================"

$AvgDiskLatencyMs = $null

try {

    $DiskLatencyCounter = Get-Counter `
        "\PhysicalDisk(_Total)\Avg. Disk sec/Transfer"

    if ($DiskLatencyCounter.CounterSamples.Count -gt 0) {

        $AvgDiskLatencyMs =
            $DiskLatencyCounter.CounterSamples[0].CookedValue * 1000

        Write-Host (
            "Average Disk Latency : {0:N2} ms/transfer" -f
            $AvgDiskLatencyMs
        )

        if ($AvgDiskLatencyMs -ge 50) {

            $LatencyScore -= 20
            $Issues += "Average disk latency is critically high."
        }
        elseif ($AvgDiskLatencyMs -ge 20) {

            $LatencyScore -= 10
            $Warnings += "Average disk latency is elevated."
        }
    }
    else {
        Write-Host "Disk latency data unavailable."
    }
}
catch {
    Write-Host "Disk latency counter unavailable."
    $Warnings += "Disk latency counter is unavailable."
}

# ======================================================================
# Network Latency
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Network Latency"
Write-Host "======================================================================"

$PingLatencyMs = $null

try {

    $PingResult = Test-Connection `
        -ComputerName "1.1.1.1" `
        -Count 1 `
        -ErrorAction Stop

    $PingLatencyMs = $PingResult.Latency

    Write-Host (
        "Ping Latency : {0:N0} ms" -f
        $PingLatencyMs
    )

    if ($PingLatencyMs -ge 200) {

        $LatencyScore -= 15
        $Issues += "Network latency is critically high."
    }
    elseif ($PingLatencyMs -ge 100) {

        $LatencyScore -= 8
        $Warnings += "Network latency is elevated."
    }
}
catch {

    Write-Host "Network latency test failed."
    $Warnings += "Network latency could not be measured."
}

# ======================================================================
# CPU / System Thermal Monitoring
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "CPU / System Thermal Monitoring"
Write-Host "======================================================================"

$CpuTempC = $null
$CpuTemperature = $null

try {

    $ThermalZones = Get-CimInstance `
        -Namespace "root\WMI" `
        -ClassName "MSAcpi_ThermalZoneTemperature"

    $ValidTemperatures = @()

    foreach ($zone in $ThermalZones) {

        if ($null -ne $zone.CurrentTemperature) {

            $Celsius = ($zone.CurrentTemperature / 10) - 273.15

            if (($Celsius -gt -50) -and ($Celsius -lt 150)) {
                $ValidTemperatures += $Celsius
            }
        }
    }

    if ($ValidTemperatures.Count -gt 0) {

        # Average all available thermal zones because zone names can vary.
        $CpuTempC = ($ValidTemperatures | Measure-Object -Average).Average

        Write-TemperatureReport `
            -Label "CPU / Package Temperature (approx):" `
            -Celsius $CpuTempC | Out-Null

        $CpuTemperature = Convert-Temperature -Celsius $CpuTempC

        # Thermal scoring is based exclusively on Celsius.
        if ($CpuTempC -ge 90) {

            $ThermalScore -= 40
            $Issues += "CPU/system temperature is critically high."
        }
        elseif ($CpuTempC -ge 85) {

            $ThermalScore -= 25
            $Warnings += "CPU/system temperature is high."
        }
        elseif ($CpuTempC -ge 75) {

            $ThermalScore -= 10
            $Warnings += "CPU/system temperature is elevated."
        }
    }
    else {

        Write-Host "CPU thermal data unavailable through WMI."
        $Warnings += "CPU thermal data is unavailable through WMI."
    }
}
catch {

    Write-Host "CPU thermal data unavailable through WMI."
    $Warnings += "CPU thermal monitoring is unavailable through WMI."
}

# ======================================================================
# System Uptime
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "System Uptime"
Write-Host "======================================================================"

$SystemUptime = $null

try {

    $OS = Get-CimInstance Win32_OperatingSystem

    $LastBootTime = $OS.LastBootUpTime
    $SystemUptime = (Get-Date) - $LastBootTime

    Write-Host (
        "System Uptime : {0} days, {1} hours, {2} minutes" -f
        $SystemUptime.Days,
        $SystemUptime.Hours,
        $SystemUptime.Minutes
    )
}
catch {

    Write-Host "System uptime unavailable."
}

# ======================================================================
# GPU Thermal Monitoring
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "GPU Thermal Monitoring"
Write-Host "======================================================================"

$GpuTempC = $null
$GpuTemperature = $null
$GpuTempFound = $false

try {

    $Namespaces = @(
        "root\WMI",
        "root\CIMV2",
        "root\Microsoft\Windows\Storage"
    )

    $TemperatureClasses = @()

    foreach ($namespace in $Namespaces) {

        try {

            $classes = Get-CimClass `
                -Namespace $namespace `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.CimClassName -match "temperature|thermal"
                }

            foreach ($class in $classes) {
                $TemperatureClasses += [PSCustomObject]@{
                    Namespace = $namespace
                    ClassName = $class.CimClassName
                }
            }
        }
        catch {
            # Ignore unavailable namespaces and continue the best-effort scan.
        }
    }

    $GpuCandidates = @()

    foreach ($entry in $TemperatureClasses) {

        try {

            $objects = Get-CimInstance `
                -Namespace $entry.Namespace `
                -ClassName $entry.ClassName `
                -ErrorAction SilentlyContinue

            foreach ($obj in $objects) {

                $nameStr = @(
                    $obj.Name
                    $obj.InstanceName
                    $obj.Description
                ) -join " "

                if ($nameStr -match "GPU|Video|Graphics|Display") {

                    $rawValue = $null

                    foreach ($propertyName in @(
                        "CurrentTemperature",
                        "Temperature",
                        "Temperature_Celsius"
                    )) {

                        if ($obj.PSObject.Properties.Name -contains $propertyName) {

                            $candidateValue = $obj.$propertyName

                            if ($null -ne $candidateValue) {
                                $rawValue = $candidateValue
                                break
                            }
                        }
                    }

                    if ($null -ne $rawValue) {

                        $rawValue = [double]$rawValue

                        # Convert common ACPI-style deci-Kelvin values.
                        if ($rawValue -gt 2000) {
                            $candidateCelsius = ($rawValue / 10) - 273.15
                        }
                        elseif ($rawValue -gt 273) {
                            $candidateCelsius = $rawValue - 273.15
                        }
                        else {
                            $candidateCelsius = $rawValue
                        }

                        if (
                            ($candidateCelsius -gt -50) -and
                            ($candidateCelsius -lt 150)
                        ) {
                            $GpuCandidates += $candidateCelsius
                        }
                    }
                }
            }
        }
        catch {
            # Continue scanning remaining thermal classes.
        }
    }

    if ($GpuCandidates.Count -gt 0) {

        $GpuTempC = ($GpuCandidates | Measure-Object -Average).Average
        $GpuTempFound = $true

        Write-TemperatureReport `
            -Label "GPU Temperature (best effort):" `
            -Celsius $GpuTempC | Out-Null

        $GpuTemperature = Convert-Temperature -Celsius $GpuTempC

        # GPU thermal scoring is based exclusively on Celsius.
        if ($GpuTempC -ge 90) {

            $ThermalScore -= 30
            $Issues += "GPU temperature is critically high."
        }
        elseif ($GpuTempC -ge 85) {

            $ThermalScore -= 20
            $Warnings += "GPU temperature is high."
        }
        elseif ($GpuTempC -ge 75) {

            $ThermalScore -= 10
            $Warnings += "GPU temperature is elevated."
        }
    }
    else {

        Write-Host "GPU thermal data unavailable through generic WMI."
        $Warnings += "GPU thermal data is unavailable through generic WMI."
    }
}
catch {

    Write-Host "GPU thermal data unavailable through generic WMI."
    $Warnings += "GPU thermal monitoring is unavailable through generic WMI."
}

# ======================================================================
# Physical Disk Thermal Monitoring
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Storage Thermal Monitoring"
Write-Host "======================================================================"

$DiskTemperatures = @()

try {

    $PhysicalDisks = Get-CimInstance `
        -Namespace "root\Microsoft\Windows\Storage" `
        -ClassName "MSFT_PhysicalDisk" `
        -ErrorAction SilentlyContinue

    if ($PhysicalDisks.Count -eq 0) {

        Write-Host "Physical disk information unavailable."
    }
    else {

        foreach ($disk in $PhysicalDisks) {

            $DiskTemperatureC = $null

            if (
                ($disk.PSObject.Properties.Name -contains "Temperature") -and
                ($null -ne $disk.Temperature)
            ) {

                $rawTemperature = [double]$disk.Temperature

                if ($rawTemperature -gt 0) {

                    if ($rawTemperature -gt 2000) {
                        $DiskTemperatureC =
                            ($rawTemperature / 10) - 273.15
                    }
                    elseif ($rawTemperature -gt 273) {
                        $DiskTemperatureC =
                            $rawTemperature - 273.15
                    }
                    else {
                        $DiskTemperatureC = $rawTemperature
                    }

                    if (
                        ($DiskTemperatureC -le -50) -or
                        ($DiskTemperatureC -ge 150)
                    ) {
                        $DiskTemperatureC = $null
                    }
                }
            }

            $DiskTemperatureObject = $null

            if ($null -ne $DiskTemperatureC) {

                $DiskTemperatureObject =
                    Convert-Temperature -Celsius $DiskTemperatureC

                Write-Host ""
                Write-Host (
                    "Disk: {0}" -f
                    $disk.FriendlyName
                )

                Write-TemperatureReport `
                    -Label "Temperature:" `
                    -Celsius $DiskTemperatureC | Out-Null

                if ($DiskTemperatureC -ge 70) {

                    $ThermalScore -= 10
                    $Warnings += (
                        "Storage temperature is elevated on {0}." -f
                        $disk.FriendlyName
                    )
                }
            }
            else {

                Write-Host ""
                Write-Host (
                    "Disk: {0}" -f
                    $disk.FriendlyName
                )

                Write-Host "Temperature : N/A"
            }

            $DiskTemperatures += [PSCustomObject]@{
                FriendlyName = $disk.FriendlyName
                DeviceId     = $disk.DeviceId
                Health       = $disk.HealthStatus
                Temperature  = $DiskTemperatureObject
            }
        }
    }
}
catch {

    Write-Host "Physical disk thermal data unavailable."
    $Warnings += "Physical disk thermal data is unavailable."
}

# ======================================================================
# Real-Time System Sampling
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Real-Time System Sampling"
Write-Host "======================================================================"

$RealtimeSamples = @()

for ($i = 1; $i -le 5; $i++) {

    try {

        $CpuLoad = (
            Get-Counter "\Processor(_Total)\% Processor Time"
        ).CounterSamples[0].CookedValue

        $InterruptLoad = (
            Get-Counter "\Processor(_Total)\% Interrupt Time"
        ).CounterSamples[0].CookedValue

        $ContextRate = (
            Get-Counter "\System\Context Switches/sec"
        ).CounterSamples[0].CookedValue

        $Sample = [PSCustomObject]@{
            Sample             = $i
            CpuLoadPercent     = [math]::Round($CpuLoad, 2)
            InterruptPercent   = [math]::Round($InterruptLoad, 2)
            ContextSwitchesSec = [math]::Round($ContextRate, 2)
        }

        $RealtimeSamples += $Sample

        Write-Host (
            "Sample {0}: CPU {1:N2}% | Interrupt {2:N2}% | Context Switches {3:N0}/sec" -f
            $i,
            $CpuLoad,
            $InterruptLoad,
            $ContextRate
        )
    }
    catch {

        Write-Host (
            "Sample {0}: Performance counters unavailable." -f
            $i
        )
    }

    Start-Sleep -Seconds 1
}

# ======================================================================
# Final Score Calculation
# ======================================================================

$LatencyScore = [math]::Max(0, [math]::Min(100, $LatencyScore))
$ThermalScore = [math]::Max(0, [math]::Min(100, $ThermalScore))

$OverallScore = [math]::Round(
    ($LatencyScore + $ThermalScore) / 2,
    0
)

# ======================================================================
# Diagnostic Summary
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Diagnostic Summary"
Write-Host "======================================================================"

Write-Host ("Latency Score : {0}/100" -f $LatencyScore)
Write-Host ("Thermal Score : {0}/100" -f $ThermalScore)
Write-Host ("Overall Score : {0}/100" -f $OverallScore)

if ($Issues.Count -gt 0) {

    Write-Host ""
    Write-Host "Critical Issues:" -ForegroundColor Red

    foreach ($issue in $Issues) {
        Write-Host ("  - {0}" -f $issue)
    }
}

if ($Warnings.Count -gt 0) {

    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor Yellow

    foreach ($warning in $Warnings) {
        Write-Host ("  - {0}" -f $warning)
    }
}

if (
    ($Issues.Count -eq 0) -and
    ($Warnings.Count -eq 0)
) {

    Write-Host ""
    Write-Host "No significant diagnostic issues detected."
}

# ======================================================================
# Recommendations
# ======================================================================

Write-Host ""
Write-Host "======================================================================"
Write-Host "Recommendations"
Write-Host "======================================================================"

if ($Issues.Count -gt 0) {

    Write-Host "Review the critical issues reported above before performing further testing."
}
elseif ($Warnings.Count -gt 0) {

    Write-Host "Review the reported warnings and repeat the audit under representative system load."
}
else {

    Write-Host "System latency and thermal indicators are within the expected diagnostic range."
}

if (-not $IsAdministrator) {

    Write-Host "Run this audit from an elevated PowerShell session for maximum sensor and counter coverage."
}

Write-Host "For accurate hardware thermal monitoring, use vendor-specific telemetry or a dedicated hardware monitoring utility when WMI data is unavailable."

# ======================================================================
# JSON Export
# ======================================================================

$DiagnosticReport = [ordered]@{

    Timestamp = (Get-Date).ToString("o")

    IsAdministrator = $IsAdministrator

    LatencyScore = $LatencyScore
    ThermalScore = $ThermalScore
    OverallScore = $OverallScore

    InterruptPercent = if ($null -ne $InterruptPercent) {
        [math]::Round($InterruptPercent, 2)
    }
    else {
        $null
    }

    DpcPercent = if ($null -ne $DpcPercent) {
        [math]::Round($DpcPercent, 2)
    }
    else {
        $null
    }

    ContextSwitchesPerSec = if ($null -ne $ContextSwitches) {
        [math]::Round($ContextSwitches, 2)
    }
    else {
        $null
    }

    AvgDiskLatencyMs = if ($null -ne $AvgDiskLatencyMs) {
        [math]::Round($AvgDiskLatencyMs, 2)
    }
    else {
        $null
    }

    PingLatencyMs = if ($null -ne $PingLatencyMs) {
        [math]::Round($PingLatencyMs, 2)
    }
    else {
        $null
    }

    # Preserve the legacy Celsius field for backward compatibility.
    CpuTempC = if ($null -ne $CpuTempC) {
        [math]::Round($CpuTempC, 2)
    }
    else {
        $null
    }

    CpuTemperature = $CpuTemperature

    GpuTempFound = $GpuTempFound

    GpuTempC = if ($null -ne $GpuTempC) {
        [math]::Round($GpuTempC, 2)
    }
    else {
        $null
    }

    GpuTemperature = $GpuTemperature

    DiskTemperatures = $DiskTemperatures

    HighLatencyDrivers = $HighLatencyDrivers

    RealtimeSamples = $RealtimeSamples

    Issues = $Issues

    Warnings = $Warnings
}

$JsonOutput = $DiagnosticReport | ConvertTo-Json -Depth 6

Write-Host ""
Write-Host "======================================================================"
Write-Host "JSON Diagnostic Report"
Write-Host "======================================================================"

Write-Host $JsonOutput

# ======================================================================
# End of Diagnostic Tool
# ======================================================================
