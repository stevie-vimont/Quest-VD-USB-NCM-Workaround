#Requires -Version 5.1
<#
.SYNOPSIS
  Quest / Virtual Desktop USB NCM workaround.

.DESCRIPTION
  Repeatedly disables and re-enables a user-selected physical network adapter
  until Windows detects a stable Meta Quest USB CDC-NCM network interface.

  This is intended as a workaround for systems where Virtual Desktop USB mode
  gets stuck in a USB reset/re-enumeration loop with some active optical
  (AOC/fiber) USB cables.

.REQUIREMENTS
  - Windows PowerShell 5.1 or later.
  - Windows NetAdapter and PnpDevice cmdlets.
  - Administrator privileges. The script requests elevation automatically.

.NOTES
  - The main Wi-Fi adapter is the recommended choice when available.
  - The Wi-Fi adapter does not need to be connected to a network.
  - Only the adapter explicitly selected by the user is toggled.
  - Quest NCM detection is restricted to Meta/Oculus USB vendor ID 2833.
  - No Quest product PID is hard-coded.
  - Hardware Wi-Fi interfaces are shown individually; HBS/MLO interfaces are
    not automatically collapsed or hidden.
  - Adapter state changes are validated through AdminStatus with timeouts.
  - The original adapter state is restored after the workaround unless another
    state is required to keep NCM stable.

.EXAMPLE
  .\Quest_VD_USB_NCM_Workaround.ps1

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Quest_VD_USB_NCM_Workaround.ps1
#>

# --------------------------- SETTINGS ---------------------------------

$StartupDelaySeconds         = 10
$MaxCycles                   = 30

$NcmDetectionWindowMs        = 1500
$NcmStableDurationMs         = 1000
$NcmStabilityTimeoutMs       = 3000
$DetectionPollMs             = 200

$AdapterStateTimeoutMs       = 5000
$AdapterStatePollMs          = 200
$MaxConsecutiveToggleErrors  = 3

# ----------------------------------------------------------------------


function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet("WARN", "ERROR")]
        [string]$Level
    )

    if ($Level -eq "ERROR") {
        Write-Host $Message -ForegroundColor Red
    }
    else {
        Write-Host $Message -ForegroundColor Yellow
    }
}

function Invoke-Beep {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Frequency,

        [Parameter(Mandatory = $true)]
        [int]$Duration
    )

    try {
        [Console]::Beep($Frequency, $Duration)
    }
    catch {
        # Audio feedback must not interrupt the workaround.
    }
}

function Test-RequiredCommands {
    $required = @(
        "Get-NetAdapter",
        "Enable-NetAdapter",
        "Disable-NetAdapter",
        "Get-PnpDevice",
        "Get-PnpDeviceProperty"
    )

    $missing = @(
        foreach ($name in $required) {
            if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
                $name
            }
        }
    )

    if ($missing.Count -gt 0) {
        Write-Host "Required Windows PowerShell command(s) are unavailable:" -ForegroundColor Red
        foreach ($name in $missing) {
            Write-Host "  - $name" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "This script requires the Windows NetAdapter and PnpDevice cmdlets."
        return $false
    }

    return $true
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Restart-AsAdministrator {
    if (-not $PSCommandPath) {
        Write-Host ""
        Write-Host "Please save this script as a .ps1 file, then run it again."
        Read-Host "Press Enter to exit"
        exit
    }

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

    exit
}

function Get-AdapterByExactName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (
        Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1
    )
}

function Get-QuestNcmDevice {
    # Check only present Meta/Oculus network-class USB devices.
    $metaNetDevices = @(
        Get-PnpDevice `
            -Class Net `
            -PresentOnly `
            -ErrorAction SilentlyContinue |
        Where-Object {
            [string]$_.InstanceId -match '(?i)^USB\\VID_2833'
        }
    )

    foreach ($dev in $metaNetDevices) {
        $instanceId = [string]$dev.InstanceId

        try {
            $compatibleIds = @(
                (Get-PnpDeviceProperty `
                    -InstanceId $instanceId `
                    -KeyName "DEVPKEY_Device_CompatibleIds" `
                    -ErrorAction Stop).Data
            )
        }
        catch {
            $compatibleIds = @()
        }

        $compatibleText = ($compatibleIds -join " ")

        $isNcm = (
            $compatibleText -match '(?i)Class_02&SubClass_0D' -or
            $dev.FriendlyName -match '(?i)(UsbNcm|CDC[\s_-]*NCM|Network Control Model)'
        )

        if ($isNcm) {
            return [PSCustomObject]@{
                FriendlyName = $dev.FriendlyName
            }
        }
    }

    # Fallback for systems where the NCM identity is clearer through
    # MSFT_NetAdapter than through the PnP compatible IDs.
    $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -ne "Not Present" -and
            [string]$_.PnPDeviceID -match '(?i)^USB\\VID_2833' -and
            $_.InterfaceDescription -match `
                '(?i)(UsbNcm|CDC[\s_-]*NCM|Network Control Model)'
        } |
        Select-Object -First 1

    if ($adapter) {
        return [PSCustomObject]@{
            FriendlyName = $adapter.InterfaceDescription
        }
    }

    return $null
}

function Wait-ForQuestNcm {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Milliseconds
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()

    while ($timer.ElapsedMilliseconds -lt $Milliseconds) {
        $device = Get-QuestNcmDevice

        if ($device) {
            return $device
        }

        $remaining = $Milliseconds - [int]$timer.ElapsedMilliseconds

        if ($remaining -le 0) {
            break
        }

        Start-Sleep -Milliseconds ([Math]::Min($DetectionPollMs, $remaining))
    }

    return $null
}

function Wait-ForStableQuestNcm {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TimeoutMilliseconds,

        [Parameter(Mandatory = $true)]
        [int]$StableMilliseconds
    )

    $overallTimer = [Diagnostics.Stopwatch]::StartNew()
    $stableTimer = $null
    $lastDevice = $null

    while ($overallTimer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $device = Get-QuestNcmDevice

        if ($device) {
            if (-not $stableTimer) {
                $stableTimer = [Diagnostics.Stopwatch]::StartNew()
            }

            $lastDevice = $device

            if ($stableTimer.ElapsedMilliseconds -ge $StableMilliseconds) {
                return $lastDevice
            }
        }
        else {
            $stableTimer = $null
            $lastDevice = $null
        }

        $remainingOverall = (
            $TimeoutMilliseconds - [int]$overallTimer.ElapsedMilliseconds
        )

        if ($remainingOverall -le 0) {
            break
        }

        $sleepMs = [Math]::Min($DetectionPollMs, $remainingOverall)

        if ($stableTimer) {
            $remainingStable = (
                $StableMilliseconds - [int]$stableTimer.ElapsedMilliseconds
            )

            if ($remainingStable -gt 0) {
                $sleepMs = [Math]::Min($sleepMs, $remainingStable)
            }
        }

        if ($sleepMs -gt 0) {
            Start-Sleep -Milliseconds $sleepMs
        }
    }

    return $null
}

function Test-LooksWireless {
    param(
        $Adapter
    )

    return (
        $Adapter.Name -match '(?i)^Wi-?Fi' -or
        $Adapter.InterfaceDescription -match '(?i)(Wi-?Fi|Wireless|WLAN|802\.11)' -or
        $Adapter.MediaType -match '(?i)802\.11' -or
        $Adapter.PhysicalMediaType -match '(?i)802\.11'
    )
}

function Get-SelectableAdapterRecords {
    # Adapter discovery:
    #
    # - Never collapse or hide wireless sibling interfaces based on HBS/MLO,
    #   PnP parentage, matching descriptions, or vendor-specific assumptions.
    # - Show every hardware Wi-Fi interface Windows exposes, even when a driver
    #   reports Status="Not Present" while the interface is administratively
    #   disabled.
    # - Keep non-wireless hardware only when it is actually present.
    # - Exclude Quest NCM itself from the list.
    #
    # Keep adapter selection transparent and explicit.

    $raw = @(
        Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.HardwareInterface -ne $true) {
                return $false
            }

            if (
                $_.InterfaceDescription -match `
                    '(?i)(UsbNcm|CDC[\s_-]*NCM|Network Control Model)'
            ) {
                return $false
            }

            $looksWireless = Test-LooksWireless -Adapter $_

            if ($looksWireless) {
                # Keep all hardware Wi-Fi interfaces, including unusual driver
                # states such as Status="Not Present" + AdminStatus="Down".
                return $true
            }

            # Exclude absent non-wireless hardware.
            return ($_.Status -ne "Not Present")
        }
    )

    if ($raw.Count -eq 0) {
        return @()
    }

    $result = foreach ($adapter in $raw) {
        [PSCustomObject]@{
            Adapter    = $adapter
            IsWireless = Test-LooksWireless -Adapter $adapter
        }
    }

    # Sort the menu for readability without removing adapters.
    return @(
        $result |
        Sort-Object `
            @{ Expression = {
                if ($_.Adapter.Name -eq "Wi-Fi") { 0 }
                elseif ($_.IsWireless)           { 1 }
                else                             { 2 }
            } }, `
            @{ Expression = { $_.Adapter.Hidden } }, `
            @{ Expression = { $_.Adapter.ifIndex } }
    )
}

function Wait-ForAdapterAdminStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Up", "Down")]
        [string]$Target,

        [int]$TimeoutMs = $AdapterStateTimeoutMs
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $last = $null

    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        $last = Get-AdapterByExactName -Name $Name

        if ($last -and $last.AdminStatus -eq $Target) {
            return [PSCustomObject]@{
                Success     = $true
                Adapter     = $last
                AdminStatus = $last.AdminStatus
                Status      = $last.Status
            }
        }

        $remaining = $TimeoutMs - [int]$timer.ElapsedMilliseconds

        if ($remaining -le 0) {
            break
        }

        Start-Sleep -Milliseconds ([Math]::Min($AdapterStatePollMs, $remaining))
    }

    return [PSCustomObject]@{
        Success     = $false
        Adapter     = $last
        AdminStatus = if ($last) { $last.AdminStatus } else { $null }
        Status      = if ($last) { $last.Status } else { $null }
    }
}

function Set-AdapterAdminState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Up", "Down")]
        [string]$Target
    )

    $current = Get-AdapterByExactName -Name $Name

    if (-not $current) {
        Write-Status `
            -Level "ERROR" `
            -Message "Adapter '$Name' cannot currently be found."

        return [PSCustomObject]@{
            Success = $false
            Adapter = $null
        }
    }

    if ($current.AdminStatus -eq $Target) {
        return [PSCustomObject]@{
            Success = $true
            Adapter = $current
        }
    }

    try {
        if ($Target -eq "Down") {
            Disable-NetAdapter `
                -Name $Name `
                -Confirm:$false `
                -ErrorAction Stop
        }
        else {
            Enable-NetAdapter `
                -Name $Name `
                -Confirm:$false `
                -ErrorAction Stop
        }
    }
    catch {
        Write-Status `
            -Level "ERROR" `
            -Message (
                "Failed to set '$Name' AdminStatus to ${Target}: " +
                "$($_.Exception.Message)"
            )

        return [PSCustomObject]@{
            Success = $false
            Adapter = $current
        }
    }

    $wait = Wait-ForAdapterAdminStatus `
        -Name $Name `
        -Target $Target `
        -TimeoutMs $AdapterStateTimeoutMs

    if (-not $wait.Success) {
        Write-Status `
            -Level "ERROR" `
            -Message (
                "Timeout waiting for '$Name' AdminStatus=$Target " +
                "(last Status=$($wait.Status), AdminStatus=$($wait.AdminStatus))."
            )

        return [PSCustomObject]@{
            Success = $false
            Adapter = $wait.Adapter
        }
    }

    return [PSCustomObject]@{
        Success = $true
        Adapter = $wait.Adapter
    }
}

# ----------------------- ADMIN ELEVATION -------------------------------

if (-not (Test-IsAdministrator)) {
    Write-Host "Restarting as Administrator..."
    Restart-AsAdministrator
}

if (-not (Test-RequiredCommands)) {
    Read-Host "Press Enter to exit"
    exit 1
}

# ---------------------------- UI ---------------------------------------

Clear-Host

Write-Host "============================================================"
Write-Host " Quest / Virtual Desktop USB NCM workaround"
Write-Host "============================================================"
Write-Host ""

$existingNcm = Get-QuestNcmDevice

if ($existingNcm) {
    $existingNcm = Wait-ForStableQuestNcm `
        -TimeoutMilliseconds $NcmStabilityTimeoutMs `
        -StableMilliseconds $NcmStableDurationMs

    if ($existingNcm) {
        Write-Host "Quest NCM is already present and stable." -ForegroundColor Green
        Write-Host "Device: $($existingNcm.FriendlyName)"
        Write-Host ""

        Invoke-Beep -Frequency 1200 -Duration 200
        Invoke-Beep -Frequency 1500 -Duration 200
        Invoke-Beep -Frequency 1800 -Duration 400

        Read-Host "Press Enter to exit"
        exit
    }
}

$records = @(Get-SelectableAdapterRecords)

if ($records.Count -eq 0) {
    Write-Status -Level "ERROR" -Message "No selectable physical network adapters were found."
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "Recommended: select the MAIN Wi-Fi adapter if available."
Write-Host "The Wi-Fi adapter does not need to be connected to a network."
Write-Host ""
Write-Host "Select the network adapter to repeatedly disable/enable:"
Write-Host ""

for ($i = 0; $i -lt $records.Count; $i++) {
    $r = $records[$i]
    $a = $r.Adapter

    $recommended = ""
    if ($a.Name -eq "Wi-Fi") {
        $recommended = "  [RECOMMENDED]"
    }

    $stateText = [string]$a.Status
    if (
        $r.IsWireless -and
        $a.Status -eq "Not Present" -and
        $a.AdminStatus -eq "Down"
    ) {
        $stateText = "Disabled (driver reports Not Present)"
    }

    Write-Host "[$($i + 1)] $($a.Name)$recommended"
    Write-Host "    $($a.InterfaceDescription)"
    Write-Host "    Status: $stateText"
    Write-Host ""
}

do {
    $choice = Read-Host "Adapter number"

    $validChoice = (
        $choice -match '^\d+$' -and
        [int]$choice -ge 1 -and
        [int]$choice -le $records.Count
    )

    if (-not $validChoice) {
        Write-Host "Invalid selection."
    }
}
until ($validChoice)

$record  = $records[[int]$choice - 1]
$adapter = $record.Adapter

$initialAdapter = Get-AdapterByExactName -Name $adapter.Name

if (-not $initialAdapter) {
    Write-Status -Level "ERROR" -Message "Selected adapter disappeared before the test could start."
    Read-Host "Press Enter to exit"
    exit
}

$originalAdminStatus  = [string]$initialAdapter.AdminStatus

if ($originalAdminStatus -notin @("Up", "Down")) {
    Write-Host ""
    Write-Host "The selected adapter has an unsupported/ambiguous AdminStatus:" -ForegroundColor Red
    Write-Host "  $originalAdminStatus" -ForegroundColor Red
    Write-Host ""
    Write-Host "No adapter state will be changed. Choose another interface or enable/disable"
    Write-Host "this interface manually in Windows and try again."
    Read-Host "Press Enter to exit"
    exit 1
}

$startedAdminDisabled = ($originalAdminStatus -eq "Down")

Write-Host ""
Write-Host "Selected: $($adapter.Name)"
Write-Host "  $($adapter.InterfaceDescription)"
Write-Host ""

if ($startedAdminDisabled) {
    Write-Host "The selected adapter is disabled and will be enabled temporarily."
    Write-Host ""
}

Write-Host "Connect the Quest with the optical/AOC cable and start Virtual Desktop."
Write-Host "Testing starts in $StartupDelaySeconds seconds."
Write-Host ""

for ($i = $StartupDelaySeconds; $i -ge 1; $i--) {
    Write-Host -NoNewline "`rStarting in $i seconds...   "
    Start-Sleep -Seconds 1
}

Write-Host ""
Write-Host ""

# ---------------------- INITIAL ADAPTER STATE --------------------------

$success                    = $false
$successCycle               = $null
$ncmDevice                  = $null
$fatalError                 = $null
$consecutiveToggleErrors    = 0
$restoredOriginalState      = $false
$postRestoreNcm             = $null
$ncmDetectedAdminStatus      = $null
$keptAlternateStateForNcm    = $false

if ($startedAdminDisabled) {
    Write-Host "Preparing selected adapter..."

    $enableInitial = Set-AdapterAdminState `
        -Name $adapter.Name `
        -Target "Up"

    if (-not $enableInitial.Success) {
        $fatalError = (
            "Could not enable the selected adapter before starting the workaround."
        )
    }
    else {
        $ncmDevice = Wait-ForQuestNcm `
            -Milliseconds $NcmDetectionWindowMs

        if ($ncmDevice) {
            $success = $true
            $successCycle = 0
            $detectedState = Get-AdapterByExactName -Name $adapter.Name
            if ($detectedState -and $detectedState.AdminStatus -in @("Up", "Down")) {
                $ncmDetectedAdminStatus = [string]$detectedState.AdminStatus
            }
        }
    }
}

if (-not $success -and -not $fatalError) {
    Write-Host "Starting workaround..."
    Write-Host ""

    Invoke-Beep -Frequency 800 -Duration 250
}

# -------------------------- WORKAROUND LOOP ----------------------------

try {
    if (-not $success -and -not $fatalError) {
        for ($cycle = 1; $cycle -le $MaxCycles; $cycle++) {

            $ncmDevice = Get-QuestNcmDevice

            if ($ncmDevice) {
                $success = $true
                $successCycle = $cycle - 1
                $detectedState = Get-AdapterByExactName -Name $adapter.Name
                if ($detectedState -and $detectedState.AdminStatus -in @("Up", "Down")) {
                    $ncmDetectedAdminStatus = [string]$detectedState.AdminStatus
                }

                break
            }

            Write-Host -NoNewline "`rCycle $cycle / $MaxCycles   "

            $cycleToggleFailed = $false

            # -------------------- OFF ----------------------------------

            $disableResult = Set-AdapterAdminState `
                -Name $adapter.Name `
                -Target "Down"

            if (-not $disableResult.Success) {
                $cycleToggleFailed = $true

                Write-Host ""
                Write-Status `
                    -Level "WARN" `
                    -Message "Cycle ${cycle}: adapter OFF transition failed."
            }

            $ncmDevice = Wait-ForQuestNcm `
                -Milliseconds $NcmDetectionWindowMs

            if ($ncmDevice) {
                $success = $true
                $successCycle = $cycle
                $detectedState = Get-AdapterByExactName -Name $adapter.Name
                if ($detectedState -and $detectedState.AdminStatus -in @("Up", "Down")) {
                    $ncmDetectedAdminStatus = [string]$detectedState.AdminStatus
                }

                break
            }

            # --------------------- ON ----------------------------------

            $enableResult = Set-AdapterAdminState `
                -Name $adapter.Name `
                -Target "Up"

            if (-not $enableResult.Success) {
                $cycleToggleFailed = $true

                Write-Host ""
                Write-Status `
                    -Level "WARN" `
                    -Message "Cycle ${cycle}: adapter ON transition failed."
            }

            $ncmDevice = Wait-ForQuestNcm `
                -Milliseconds $NcmDetectionWindowMs

            if ($ncmDevice) {
                $success = $true
                $successCycle = $cycle
                $detectedState = Get-AdapterByExactName -Name $adapter.Name
                if ($detectedState -and $detectedState.AdminStatus -in @("Up", "Down")) {
                    $ncmDetectedAdminStatus = [string]$detectedState.AdminStatus
                }

                break
            }

            if ($cycleToggleFailed) {
                $consecutiveToggleErrors++
            }
            else {
                $consecutiveToggleErrors = 0
            }

            if (
                $consecutiveToggleErrors -ge
                $MaxConsecutiveToggleErrors
            ) {
                $fatalError = (
                    "Adapter state transitions failed during " +
                    "$consecutiveToggleErrors consecutive cycle(s). " +
                    "Check the error message above."
                )

                Write-Status -Level "ERROR" -Message $fatalError
                break
            }

            Invoke-Beep -Frequency 550 -Duration 70
        }
    }
}
finally {
    # --------------------- RESTORE ORIGINAL STATE ----------------------

    $restoreTarget = if ($startedAdminDisabled) { "Down" } else { "Up" }

    $restore = Set-AdapterAdminState `
        -Name $adapter.Name `
        -Target $restoreTarget

    $restoredOriginalState = $restore.Success

    if (-not $restore.Success) {
        Write-Status `
            -Level "WARN" `
            -Message "Could not fully restore the selected adapter to its original administrative state."
    }
}

# ----------------------- NCM STABILITY CHECK ---------------------------

if ($success) {
    Write-Host ""

    $postRestoreNcm = Wait-ForStableQuestNcm `
        -TimeoutMilliseconds $NcmStabilityTimeoutMs `
        -StableMilliseconds $NcmStableDurationMs

    if ($postRestoreNcm) {
        $ncmDevice = $postRestoreNcm
    }
    else {
        Write-Status `
            -Level "WARN" `
            -Message "Quest NCM did not remain stable after adapter restoration."

        $restoreTarget = if ($startedAdminDisabled) { "Down" } else { "Up" }

        if (
            $ncmDetectedAdminStatus -in @("Up", "Down") -and
            $ncmDetectedAdminStatus -ne $restoreTarget
        ) {
            Write-Host "NCM disappeared after restoring the adapter to its original state."
            Write-Host "Trying the adapter state in which NCM was actually detected:"
            Write-Host "  AdminStatus=$ncmDetectedAdminStatus"

            $recoveryState = Set-AdapterAdminState `
                -Name $adapter.Name `
                -Target $ncmDetectedAdminStatus

            if ($recoveryState.Success) {
                $recoveryNcm = Wait-ForStableQuestNcm `
                    -TimeoutMilliseconds $NcmStabilityTimeoutMs `
                    -StableMilliseconds $NcmStableDurationMs

                if ($recoveryNcm) {
                    $ncmDevice = $recoveryNcm
                    $postRestoreNcm = $recoveryNcm
                    $keptAlternateStateForNcm = $true
                    $restoredOriginalState = $false

                    Write-Status `
                        -Level "WARN" `
                        -Message (
                            "Quest NCM returned in AdminStatus=$ncmDetectedAdminStatus. " +
                            "The selected adapter will be left in that state to preserve NCM."
                        )
                }
                else {
                    Write-Status `
                        -Level "ERROR" `
                        -Message "Quest NCM did not become stable in the previously successful adapter state."

                    $restoreAgain = Set-AdapterAdminState `
                        -Name $adapter.Name `
                        -Target $restoreTarget

                    $restoredOriginalState = $restoreAgain.Success
                }
            }
        }
    }
}

# ----------------------------- RESULT ----------------------------------

Write-Host ""

if ($success -and $keptAlternateStateForNcm) {
    Write-Host "============================================================"
    Write-Host " SUCCESS - Quest USB NCM detected" -ForegroundColor Green
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "NCM disappeared after the selected adapter was restored to its original state,"
    Write-Host "but returned in the adapter state where NCM had previously been detected."
    Write-Host ""
    Write-Host "The selected adapter has therefore been left in that alternate state to preserve NCM."
    Write-Host ""
    Write-Host ""

    Invoke-Beep -Frequency 1100 -Duration 180
    Invoke-Beep -Frequency 1450 -Duration 180
    Invoke-Beep -Frequency 1800 -Duration 500
}
elseif ($success -and $postRestoreNcm) {
    Write-Host "============================================================"
    Write-Host " SUCCESS - Quest USB NCM detected" -ForegroundColor Green
    Write-Host "============================================================"
    Write-Host ""

    if ($successCycle -eq 0) {
        Write-Host "Detected while preparing the adapter."
    }
    elseif ($null -ne $successCycle) {
        Write-Host "Detected on cycle $successCycle."
    }

    Write-Host "Device: $($ncmDevice.FriendlyName)"

    if ($restoredOriginalState) {
        Write-Host "Original adapter state restored."
    }

    Write-Host ""

    Invoke-Beep -Frequency 1100 -Duration 180
    Invoke-Beep -Frequency 1450 -Duration 180
    Invoke-Beep -Frequency 1800 -Duration 500
}
elseif ($success) {
    Write-Host "============================================================"
    Write-Host " WARNING - NCM was detected but did not remain available" -ForegroundColor Yellow
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "The workaround triggered NCM, but the interface was not present"
    Write-Host "after the final restoration/recovery checks."
    Write-Host ""
    Write-Host ""

    Invoke-Beep -Frequency 650 -Duration 250
    Invoke-Beep -Frequency 450 -Duration 600
}
else {
    Write-Host "============================================================"
    Write-Host " No stable Quest NCM device detected"
    Write-Host "============================================================"
    Write-Host ""

    if ($fatalError) {
        Write-Host "Reason:"
        Write-Host "  $fatalError"
        Write-Host ""
    }
    else {
        Write-Host "No Quest NCM device was detected after $MaxCycles cycles."
        Write-Host ""
    }
    Write-Host ""

    Invoke-Beep -Frequency 350 -Duration 800
}

Write-Host ""
Read-Host "Press Enter to close"
