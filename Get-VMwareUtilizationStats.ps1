[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "FQDN or IP address of the vCenter Server or standalone ESXi host.")]
    [Alias('VIServer')]
    [string]$VCenterServer,

    [Parameter(HelpMessage = "Read-only vCenter or ESXi credential. If omitted, you will be prompted securely.")]
    [PSCredential]$Credential,

    [Parameter(HelpMessage = "Number of days of history to collect, ending at -EndDate. Ignored if -StartDate is supplied.")]
    [ValidateRange(1, 365)]
    [int]$Days = 14,

    [Parameter(HelpMessage = "Explicit start of the collection window. Overrides -Days.")]
    [datetime]$StartDate = [datetime]::MinValue,

    [Parameter(HelpMessage = "End of the collection window. Defaults to now.")]
    [datetime]$EndDate = (Get-Date),

    [Parameter(HelpMessage = "Only collect stats for VMs in these cluster(s). Default = all clusters.")]
    [string[]]$ClusterName,

    [Parameter(HelpMessage = "Only collect stats for VMs matching these name(s)/pattern(s). Default = all VMs.")]
    [string[]]$VMName,

    [Parameter(HelpMessage = "Include powered-off VMs (they will typically show no/limited data).")]
    [switch]$IncludePoweredOffVMs,

    [Parameter(HelpMessage = "Folder to write the CSV report(s) and run log to.")]
    [string]$OutputFolder,

    [Parameter(HelpMessage = "Number of VMs to query per Get-Stat call.")]
    [ValidateRange(1, 100)]
    [int]$BatchSize = 15,

    [Parameter(HelpMessage = "Collect retained real-time samples instead of historical rollups. Standalone ESXi always uses real-time mode.")]
    [switch]$Realtime,

    [Parameter(HelpMessage = "Retained real-time samples from the last X minutes.")]
    [ValidateRange(1, 60)]
    [int]$RealtimeMinutes = 60,

    [Parameter(HelpMessage = "Set PowerCLI to ignore untrusted/self-signed certificate errors for this session only.")]
    [switch]$AllowSelfSignedCertificate,

    [Parameter(HelpMessage = "Automatically install VMware.PowerCLI (current user scope) if missing, without prompting.")]
    [switch]$AutoInstallPowerCLI
)

if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $OutputFolder = Join-Path -Path $PSScriptRoot -ChildPath "VMwareUtilizationReport_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

function Test-PowerCLIAvailability {
    [CmdletBinding()]
    param(
        [switch]$AutoInstall
    )

    if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
        Write-Warning "The VMware.PowerCLI module was not found for the current user."

        if (-not $AutoInstall) {
            $response = Read-Host "Install VMware.PowerCLI from the PowerShell Gallery now (current user scope)? (Y/N)"
            if ($response -notmatch '^[Yy]') {
                throw "VMware.PowerCLI is required. Install it manually with: Install-Module -Name VMware.PowerCLI -Scope CurrentUser"
            }
        }

        Write-Host "Installing VMware.PowerCLI (this may take a few minutes)..." -ForegroundColor Cyan
        Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop
}

function Get-StatIntervalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime]$StartDate,
        [Parameter(Mandatory)] [datetime]$EndDate,
        [Parameter(Mandatory)] $HistoricalIntervals
    )

    $intervals = $HistoricalIntervals | Where-Object { $_.Enabled } | Sort-Object SamplingPeriod

    $plan = [System.Collections.Generic.List[object]]::new()
    $cursor = $EndDate

    foreach ($iv in $intervals) {
        if ($cursor -le $StartDate) { break }

        $retentionCutoff = $EndDate.AddSeconds(-1 * $iv.Length)
        $segmentStart = if ($retentionCutoff -gt $StartDate) { $retentionCutoff } else { $StartDate }

        if ($segmentStart -lt $cursor) {
            $plan.Add([PSCustomObject]@{
                    Mode                  = 'Historical'
                    IntervalMins          = [int]($iv.SamplingPeriod / 60)
                    SampleIntervalSeconds = [int]$iv.SamplingPeriod
                    Level                 = $iv.Level
                    Start                 = $segmentStart
                    Finish                = $cursor
                })
            $cursor = $segmentStart
        }
    }

    return @($plan | Sort-Object Start)
}

function Split-IntoBatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$InputArray,
        [Parameter(Mandatory)] [int]$BatchSize
    )
    for ($i = 0; $i -lt $InputArray.Count; $i += $BatchSize) {
        $endIndex = [math]::Min($i + $BatchSize - 1, $InputArray.Count - 1)
        , $InputArray[$i..$endIndex]
    }
}

# Translate a virtual disk's controller and unit number into a performance instance name (scsi0:0)
function Get-VirtualDiskAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $DiskDevice,
        [Parameter(Mandatory)] [array]$AllDevices
    )

    $controller = $AllDevices | Where-Object { $_.Key -eq $DiskDevice.ControllerKey } | Select-Object -First 1
    if (-not $controller -or $null -eq $DiskDevice.UnitNumber) { return $null }

    $controllerDescription = "$($controller.GetType().Name) $($controller.DeviceInfo.Label)"
    # Detects if its a SCSI, SATA, NVME, or IDE controller and returns a prefix for the performance instance name.
    $prefix = switch -Regex ($controllerDescription) {
        'SCSI' { 'scsi'; break }
        'SATA|AHCI' { 'sata'; break }
        'NVME' { 'nvme'; break }
        'IDE' { 'ide'; break }
        default { $null }
    }
    if (-not $prefix) { return $null }

    return "$prefix$($controller.BusNumber):$($DiskDevice.UnitNumber)"
}

# VMware label the performance data with controller and unit numbers, but the instance names are not guaranteed to match the virtual disk labels. 
# This function attempts to resolve the best match between the available performance instance names and the candidate names derived from the virtual disk configuration.
# (scsi0:0 = ReadThroughput_MBps, scsi0:1 = WriteThroughput_MBps, etc.)
function Resolve-VirtualDiskInstance {
    [CmdletBinding()]
    param(
        [string[]]$AvailableInstances,
        [string[]]$Candidates,
        [int]$VirtualDiskCount
    )

    # Given a list of available performance instance names and a list of candidate names (from the VM's virtual disk configuration), attempt to find the best match. 
    foreach ($candidate in ($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $match = $AvailableInstances | Where-Object { $_ -eq $candidate } | Select-Object -First 1
        if ($match) { return $match }

        $normalizedCandidate = $candidate -replace '[^a-zA-Z0-9]', ''
        if ($normalizedCandidate.Length -lt 8) { continue }
        $match = $AvailableInstances | Where-Object {
            $normalizedInstance = $_ -replace '[^a-zA-Z0-9]', ''
            $normalizedInstance -eq $normalizedCandidate
        } | Select-Object -First 1
        if ($match) { return $match }
    }

    if ($VirtualDiskCount -eq 1 -and $AvailableInstances.Count -eq 1) {
        return $AvailableInstances[0]
    }
    return $null
}

# Read VMWare and convert them into key and value pairs.
function ConvertFrom-VMwareGuestDetailedData {
    [CmdletBinding()]
    param([string]$DetailedData)

    $result = @{}
    if ([string]::IsNullOrWhiteSpace($DetailedData)) { return $result }

    foreach ($match in [regex]::Matches($DetailedData, "(?<key>[A-Za-z][A-Za-z0-9_]*)='(?<value>[^']*)'")) {
        $result[$match.Groups['key'].Value] = $match.Groups['value'].Value
    }
    return $result
}

# Gather VM inventory data (OS, IPs, disks, etc.) from the VM's configuration and guest properties.
function Get-VMInventoryData {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $VM)

    $config = $VM.ExtensionData.Config
    $guest = $VM.ExtensionData.Guest
    $guestDetails = ConvertFrom-VMwareGuestDetailedData -DetailedData ([string]$guest.GuestDetailedData)

    $osName = @(
        $guestDetails['prettyName']
        $guest.GuestFullName
        $config.GuestFullName
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

    $osVersion = $guestDetails['distroVersion']
    if ([string]::IsNullOrWhiteSpace($osVersion) -and $osName -match '(?i)Windows Server\s+(\d{4}(?:\s+R2)?)') {
        $osVersion = $Matches[1]
    }
    elseif ([string]::IsNullOrWhiteSpace($osVersion) -and $osName -match '(?i)Windows\s+(\d+(?:\.\d+)*)') {
        $osVersion = $Matches[1]
    }

    $osArchitecture = $null
    if ($guestDetails['bitness'] -match '^(32|64)$') {
        $osArchitecture = "$($guestDetails['bitness'])-bit"
    }
    elseif ($osName -match '(?i)\((32|64)-bit\)') {
        $osArchitecture = "$($Matches[1])-bit"
    }
    elseif ([string]$config.GuestId -match '(?i)64Guest$') {
        $osArchitecture = '64-bit'
    }

    $ipAddresses = [System.Collections.Generic.List[string]]::new()
    foreach ($address in @($VM.Guest.IPAddress)) {
        if ([string]::IsNullOrWhiteSpace($address)) { continue }
        $parsedAddress = $null
        if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsedAddress)) { continue }
        if ([System.Net.IPAddress]::IsLoopback($parsedAddress)) { continue }
        if ($address -like '169.254.*' -or $address -like 'fe80:*') { continue }
        if (-not $ipAddresses.Contains($address)) { $ipAddresses.Add($address) }
    }
    if ($ipAddresses.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($guest.IpAddress)) {
        $ipAddresses.Add([string]$guest.IpAddress)
    }

    $firmware = switch ([string]$config.Firmware) {
        'efi' { 'UEFI' }
        'bios' { 'BIOS' }
        default { $null }
    }

    $guestDisks = @($guest.Disk | Where-Object { $_.Capacity -gt 0 })
    if ($guestDisks.Count -gt 0) {
        $usedBytes = ($guestDisks | ForEach-Object { [double]$_.Capacity - [double]$_.FreeSpace } | Measure-Object -Sum).Sum
        $storageInUseGB = [math]::Round($usedBytes / 1GB, 2)
    }
    elseif ($null -ne $VM.UsedSpaceGB) {
        $storageInUseGB = [math]::Round([double]$VM.UsedSpaceGB, 2)
    }
    else {
        $storageInUseGB = $null
    }

    [PSCustomObject]@{
        IPAddresses     = $ipAddresses -join '; '
        OSName          = [string]$osName
        OSVersion       = [string]$osVersion
        OSArchitecture  = $osArchitecture
        BootType        = $firmware
        NetworkAdapters = [int]$VM.ExtensionData.Summary.Config.NumEthernetCards
        NumberOfDisks   = [int]$VM.ExtensionData.Summary.Config.NumVirtualDisks
        StorageInUseGB  = $storageInUseGB
    }
}

$StatDefinitions = @(
    [PSCustomObject]@{ MetricId = 'cpu.usage.average'; RollupType = 'average'; Factor = 1; PerVCpu = $false; AverageColumn = 'CPU utilization percentage average'; MaximumColumn = 'CPU utilization percentage maximum' }
    # cpu.ready.summation returns ms of ready-time per sample; dividing by sample seconds yields ms/sec, *0.1 = % per vCPU, then PerVCpu divides by vCPU count.
    [PSCustomObject]@{ MetricId = 'cpu.ready.summation'; RollupType = 'summation'; Factor = 0.1; PerVCpu = $true; AverageColumn = 'CPU ready percentage average'; MaximumColumn = 'CPU ready percentage maximum' }
    [PSCustomObject]@{ MetricId = 'mem.usage.average'; RollupType = 'average'; Factor = 1; PerVCpu = $false; AverageColumn = 'Memory utilization percentage average'; MaximumColumn = 'Memory utilization percentage maximum' }
    # mem.vmmemctl.average (balloon) is reported in KB; convert to MB.
    [PSCustomObject]@{ MetricId = 'mem.vmmemctl.average'; RollupType = 'average'; Factor = (1 / 1KB); PerVCpu = $false; AverageColumn = 'Memory balloon average (MB)'; MaximumColumn = 'Memory balloon maximum (MB)' }
    [PSCustomObject]@{ MetricId = 'net.received.average'; RollupType = 'average'; Factor = (1 / 1KB); PerVCpu = $false; AverageColumn = 'Network In throughput average (MB per second)'; MaximumColumn = 'Network In throughput maximum (MB per second)' }
    [PSCustomObject]@{ MetricId = 'net.transmitted.average'; RollupType = 'average'; Factor = (1 / 1KB); PerVCpu = $false; AverageColumn = 'Network Out throughput average (MB per second)'; MaximumColumn = 'Network Out throughput maximum (MB per second)' }
)
$PerDiskStatDefinitions = @(
    [PSCustomObject]@{ Code = 'ReadThroughput_MBps'; MetricId = 'virtualdisk.read.average'; Factor = (1 / 1KB) }
    [PSCustomObject]@{ Code = 'WriteThroughput_MBps'; MetricId = 'virtualdisk.write.average'; Factor = (1 / 1KB) }
    [PSCustomObject]@{ Code = 'ReadIOPS'; MetricId = 'virtualdisk.numberreadaveraged.average'; Factor = 1 }
    [PSCustomObject]@{ Code = 'WriteIOPS'; MetricId = 'virtualdisk.numberwriteaveraged.average'; Factor = 1 }
)
$StatIds = $StatDefinitions.MetricId
$PerDiskStatIds = $PerDiskStatDefinitions.MetricId
$StatDefLookup = @{}
foreach ($d in $StatDefinitions) { $StatDefLookup[$d.MetricId] = $d }
$PerDiskStatDefLookup = @{}
foreach ($d in $PerDiskStatDefinitions) { $PerDiskStatDefLookup[$d.MetricId] = $d }

if ($StartDate -eq [datetime]::MinValue) {
    $StartDate = $EndDate.AddDays(-$Days)
}
if ($StartDate -ge $EndDate) {
    throw "StartDate ($StartDate) must be earlier than EndDate ($EndDate)."
}

New-Item -ItemType Directory -Path $OutputFolder -Force -ErrorAction Stop | Out-Null
Start-Transcript -Path (Join-Path $OutputFolder 'CollectionLog.txt') -ErrorAction SilentlyContinue | Out-Null

$viConnection = $null
$batchErrorCount = 0

try {
    Write-Host "=== VMware utilization collection ===" -ForegroundColor Cyan
    Write-Host "vCenter        : $VCenterServer"
    Write-Host "Requested window: $StartDate  ->  $EndDate"
    Write-Host "Output folder  : $OutputFolder"
    Write-Host ""

    Test-PowerCLIAvailability -AutoInstall:$AutoInstallPowerCLI

    Set-PowerCLIConfiguration -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null
    if ($AllowSelfSignedCertificate) {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
    }

    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter read-only vCenter or ESXi credentials for $VCenterServer"
    }

    Write-Host "Connecting to $VCenterServer ..."
    try {
        $viConnection = Connect-VIServer -Server $VCenterServer -Credential $Credential -ErrorAction Stop
    }
    catch {
        throw "Failed to connect to '$VCenterServer'. Verify the server name, that the account has read-only access, and (if using a self-signed certificate) consider -AllowSelfSignedCertificate. Original error: $($_.Exception.Message)"
    }
    $serviceInstance = Get-View -Server $viConnection -Id 'ServiceInstance'
    $isStandaloneEsxi = $serviceInstance.Content.About.ApiType -eq 'HostAgent'
    $endpointType = if ($isStandaloneEsxi) { 'standalone ESXi host' } else { 'vCenter Server' }
    Write-Host "Connected as $($viConnection.User) to $endpointType (read-only session)." -ForegroundColor Green

    # Resolve target VM scope
    $vmParams = @{ Server = $viConnection }
    # Optional ClusterName filter is only valid when connected to a vCenter Server, not a standalone ESXi host.
    if ($ClusterName) {
        if ($isStandaloneEsxi) {
            Write-Warning 'ClusterName is ignored when connected directly to a standalone ESXi host.'
        }
        else {
            $vmParams['Location'] = Get-Cluster -Name $ClusterName -Server $viConnection -ErrorAction Stop
        }
    }
    if ($VMName) {
        $vmParams['Name'] = $VMName
    }
    # Include powered-off VMs by default; filter them out later if -IncludePoweredOffVMs is not specified.
    $targetVMs = @(Get-VM @vmParams -ErrorAction Stop)
    if (-not $IncludePoweredOffVMs) {
        $targetVMs = @($targetVMs | Where-Object { $_.PowerState -eq 'PoweredOn' })
    }
    if ($targetVMs.Count -eq 0) {
        throw "No VMs matched the requested scope (ClusterName/VMName/power state filters)."
    }
    Write-Host "Target VM scope: $($targetVMs.Count) VM(s)."

    # Build a VMHost Cluster lookup table
    $clusterMap = @{}
    if (-not $isStandaloneEsxi) {
        try {
            foreach ($cl in (Get-Cluster -Server $viConnection -ErrorAction Stop)) {
                foreach ($vmhost in ($cl | Get-VMHost -Server $viConnection -ErrorAction Stop)) {
                    $clusterMap[$vmhost.Name] = $cl.Name
                }
            }
        }
        catch {
            Write-Warning "Could not fully resolve cluster membership; Cluster column may show '(unknown)'. $_"
        }
    }

    # vCenter stores historical rollups. A standalone ESXi host exposes only its short real-time window.
    $perfManager = Get-View -Server $viConnection -Id $serviceInstance.Content.PerfManager
    # Choosing real-time mode overrides -Days/-StartDate/-EndDate, and is the only option for standalone ESXi.
    if ($isStandaloneEsxi -or $Realtime) {
        $realtimeSampleSeconds = 20
        try {
            $providerSummary = $perfManager.QueryPerfProviderSummary($targetVMs[0].ExtensionData.MoRef)
            if ($providerSummary.RefreshRate -gt 0) {
                $realtimeSampleSeconds = [int]$providerSummary.RefreshRate
            }
        }
        catch {
            Write-Warning "Could not query the real-time refresh rate; assuming 20 seconds for IOPS conversion. $($_.Exception.Message)"
        }
        # Calculates how many samples are needed to cover the requested number of minutes.
        $realtimeMaxSamples = [int][math]::Ceiling(($RealtimeMinutes * 60) / $realtimeSampleSeconds)
        $intervalPlan = @([PSCustomObject]@{
                Mode                  = 'Realtime'
                IntervalMins          = 0
                SampleIntervalSeconds = $realtimeSampleSeconds
                Level                 = 'n/a'
                Start                 = $EndDate.AddMinutes(-$RealtimeMinutes)
                Finish                = $EndDate
                MaxSamples            = $realtimeMaxSamples
            })
        if ($isStandaloneEsxi) {
            Write-Warning "Connected directly to ESXi. The requested -Days/-StartDate range is unavailable; collecting up to the latest $RealtimeMinutes minute(s) of real-time samples instead."
        }
        else {
            Write-Host "Real-time mode selected; -Days, -StartDate and -EndDate are ignored." -ForegroundColor Yellow
        }
    }
    else {
        $historicalIntervals = $perfManager.HistoricalInterval
        $intervalPlan = Get-StatIntervalPlan -StartDate $StartDate -EndDate $EndDate -HistoricalIntervals $historicalIntervals
        if ($intervalPlan.Count -eq 0) {
            throw "No enabled historical statistics intervals were found on '$VCenterServer'; cannot collect historical performance data."
        }
    }

    Write-Host ""
    Write-Host "Collection plan:" -ForegroundColor Cyan
    foreach ($seg in $intervalPlan) {
        if ($seg.Mode -eq 'Realtime') {
            Write-Host ("  {0}-second real-time samples (up to {1} minutes)" -f $seg.SampleIntervalSeconds, $RealtimeMinutes)
        }
        else {
            Write-Host ("  {0,4} min samples (level {1})  :  {2}  ->  {3}" -f $seg.IntervalMins, $seg.Level, $seg.Start, $seg.Finish)
        }
    }
    $actualEarliest = $intervalPlan[0].Start
    if (-not $isStandaloneEsxi -and -not $Realtime -and $actualEarliest -gt $StartDate) {
        Write-Warning "Requested start ($StartDate) is older than what vCenter's statistics retention currently keeps. Actual data coverage begins at $actualEarliest."
    }
    Write-Host ""

    # Real-time samples are short-retention data (normally 20-second).

    $summaryAccumulator = @{}
    $perDiskAccumulator = @{}
    $perDiskInstances = @{}
    $perDiskCollectionErrorCount = 0
    $vmsWithData = [System.Collections.Generic.HashSet[string]]::new()
    $batches = @(Split-IntoBatches -InputArray $targetVMs -BatchSize $BatchSize)
    $totalSteps = $intervalPlan.Count * $batches.Count
    $step = 0

    foreach ($segment in $intervalPlan) {
        $batchIndex = 0
        foreach ($batch in $batches) {
            $batchIndex++
            $step++
            $status = if ($segment.Mode -eq 'Realtime') { "Real-time batch $batchIndex of $($batches.Count)" } else { "Interval $($segment.IntervalMins) min - batch $batchIndex of $($batches.Count)" }
            Write-Progress -Activity "Collecting VMware utilization statistics" `
                -Status $status `
                -PercentComplete ([math]::Min(100, ($step / $totalSteps) * 100))

            try {
                if ($segment.Mode -eq 'Realtime') {
                    $statResults = @(Get-Stat -Entity $batch -Stat $StatIds -Realtime -MaxSamples $segment.MaxSamples `
                            -Instance '' -Server $viConnection -ErrorAction Stop
                    )
                }
                else {
                    $statResults = @(Get-Stat -Entity $batch -Stat $StatIds -Start $segment.Start -Finish $segment.Finish `
                            -IntervalMins $segment.IntervalMins -Instance '' -Server $viConnection -ErrorAction Stop
                    )
                }
            }
            catch {
                Write-Warning "Batch $batchIndex ($($segment.Start) -> $($segment.Finish)) failed: $($_.Exception.Message)"
                $batchErrorCount++
                continue
            }

            $perDiskStatResults = @()
            try {
                if ($segment.Mode -eq 'Realtime') {
                    $perDiskStatResults = @(Get-Stat -Entity $batch -Stat $PerDiskStatIds -Realtime -MaxSamples $segment.MaxSamples `
                            -Server $viConnection -ErrorAction Stop)
                }
                else {
                    $perDiskStatResults = @(Get-Stat -Entity $batch -Stat $PerDiskStatIds -Start $segment.Start -Finish $segment.Finish `
                            -IntervalMins $segment.IntervalMins -Server $viConnection -ErrorAction Stop)
                }
            }
            catch {
                Write-Warning "Per-disk statistics failed for batch ${batchIndex}: $($_.Exception.Message)"
                $perDiskCollectionErrorCount++
            }

            if (-not $statResults -and -not $perDiskStatResults) { continue }

            foreach ($stat in $statResults) {
                $statDef = $StatDefLookup[$stat.MetricId]
                if (-not $statDef) { continue }

                $value = [double]$stat.Value
                if ($statDef.RollupType -eq 'summation') {
                    $sampleIntervalSeconds = if ($stat.IntervalSecs -gt 0) { $stat.IntervalSecs } else { $segment.SampleIntervalSeconds }
                    $value = $value / $sampleIntervalSeconds
                }

                $key = "$($stat.Entity)|$($stat.MetricId)"
                if (-not $summaryAccumulator.ContainsKey($key)) {
                    $summaryAccumulator[$key] = [System.Collections.Generic.List[double]]::new()
                }
                $summaryAccumulator[$key].Add($value)
                [void]$vmsWithData.Add($stat.Entity)
            }

            foreach ($stat in $perDiskStatResults) {
                $statDef = $PerDiskStatDefLookup[$stat.MetricId]
                if (-not $statDef -or [string]::IsNullOrWhiteSpace($stat.Instance)) { continue }

                $instance = [string]$stat.Instance
                $key = "$($stat.Entity)|$($stat.MetricId)|$instance"
                if (-not $perDiskAccumulator.ContainsKey($key)) {
                    $perDiskAccumulator[$key] = [System.Collections.Generic.List[double]]::new()
                }
                $perDiskAccumulator[$key].Add([double]$stat.Value)

                if (-not $perDiskInstances.ContainsKey([string]$stat.Entity)) {
                    $perDiskInstances[[string]$stat.Entity] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                [void]$perDiskInstances[[string]$stat.Entity].Add($instance)
            }
        }
    }
    Write-Progress -Activity "Collecting VMware utilization statistics" -Completed

    # Build the per-VM summary (Avg / Max per metric)
    $summaryRows = foreach ($vm in $targetVMs) {
        $inventory = Get-VMInventoryData -VM $vm
        $row = [ordered]@{
            'Server name'                                    = $vm.Name
            'Cluster'                                        = if ($isStandaloneEsxi) { '(standalone ESXi)' } elseif ($clusterMap.ContainsKey($vm.VMHost.Name)) { $clusterMap[$vm.VMHost.Name] } else { '(unknown)' }
            'IP addresses'                                   = $inventory.IPAddresses
            'PowerState'                                     = $vm.PowerState.ToString()
            'Cores'                                          = $vm.NumCpu
            'Memory (In MB)'                                 = [int]$vm.ExtensionData.Config.Hardware.MemoryMB
            'OS name'                                        = $inventory.OSName
            'OS version'                                     = $inventory.OSVersion
            'OS architecture'                                = $inventory.OSArchitecture
            'Server type'                                    = 'Virtual'
            'Hypervisor'                                     = 'Vmware'
            'CPU utilization percentage average'             = $null
            'CPU utilization percentage maximum'             = $null
            'CPU ready percentage average'                   = $null
            'CPU ready percentage maximum'                   = $null
            'Memory utilization percentage average'          = $null
            'Memory utilization percentage maximum'          = $null
            'Memory balloon average (MB)'                    = $null
            'Memory balloon maximum (MB)'                    = $null
            'Network adapters'                               = $inventory.NetworkAdapters
            'Network In throughput average (MB per second)'  = $null
            'Network In throughput maximum (MB per second)'  = $null
            'Network Out throughput average (MB per second)' = $null
            'Network Out throughput maximum (MB per second)' = $null
            'Boot Type'                                      = $inventory.BootType
            'Number of disks'                                = $inventory.NumberOfDisks
            'Storage in use (In GB)'                         = $inventory.StorageInUseGB
        }

        foreach ($def in $StatDefinitions) {
            $key = "$($vm.Name)|$($def.MetricId)"
            $values = $summaryAccumulator[$key]

            if ($values -and $values.Count -gt 0) {
                $avg = ([double](($values | Measure-Object -Average).Average)) * $def.Factor
                $max = ([double](($values | Measure-Object -Maximum).Maximum)) * $def.Factor

                if ($def.PerVCpu -and $vm.NumCpu -gt 0) {
                    $avg = $avg / $vm.NumCpu
                    $max = $max / $vm.NumCpu
                }

                $row[$def.AverageColumn] = [math]::Round($avg, 2)
                $row[$def.MaximumColumn] = [math]::Round($max, 2)
            }
            else {
                $row[$def.AverageColumn] = $null
                $row[$def.MaximumColumn] = $null
            }
        }

        [PSCustomObject]$row
    }

    $summaryPath = Join-Path $OutputFolder 'UtilizationSummary.csv'

    # Collect the inventory and statistics that will become Disk 1, Disk 2, etc.
    $diskSummaryRows = foreach ($vm in $targetVMs) {
        $allDevices = @($vm.ExtensionData.Config.Hardware.Device)
        $virtualDisks = @($allDevices | Where-Object {
                $_.DeviceInfo.Label -like 'Hard disk *' -and $null -ne $_.CapacityInKB
            } | Sort-Object @{ Expression = {
                    if ($_.DeviceInfo.Label -match '(\d+)$') { [int]$Matches[1] } else { [int]::MaxValue }
                } 
            })
        $availableInstances = if ($perDiskInstances.ContainsKey($vm.Name)) {
            @($perDiskInstances[$vm.Name] | Sort-Object)
        }
        else {
            @()
        }

        foreach ($disk in $virtualDisks) {
            $diskName = [string]$disk.DeviceInfo.Label
            $diskNumber = if ($diskName -match '(\d+)$') { [int]$Matches[1] } else { $null }
            $controllerAddress = Get-VirtualDiskAddress -DiskDevice $disk -AllDevices $allDevices
            $performanceInstance = Resolve-VirtualDiskInstance -AvailableInstances $availableInstances `
                -Candidates @(
                $controllerAddress,
                $diskName,
                [string]$disk.Key,
                [string]$disk.Backing.Uuid,
                [string]$disk.Backing.LunUuid,
                [string]$disk.Backing.DeviceName,
                [string]$disk.Backing.FileName
            ) -VirtualDiskCount $virtualDisks.Count

            $capacityBytes = if ($disk.CapacityInBytes -gt 0) {
                [double]$disk.CapacityInBytes
            }
            else {
                [double]$disk.CapacityInKB * 1KB
            }
            $row = [ordered]@{
                VMName     = $vm.Name
                DiskNumber = $diskNumber
                CapacityGB = [math]::Round($capacityBytes / 1GB, 2)
            }

            $missingMetrics = [System.Collections.Generic.List[string]]::new()
            foreach ($def in $PerDiskStatDefinitions) {
                $values = if ($performanceInstance) {
                    $perDiskAccumulator["$($vm.Name)|$($def.MetricId)|$performanceInstance"]
                }
                else {
                    $null
                }

                if ($values -and $values.Count -gt 0) {
                    $avg = ([double](($values | Measure-Object -Average).Average)) * $def.Factor
                    $max = ([double](($values | Measure-Object -Maximum).Maximum)) * $def.Factor
                    $row["$($def.Code)_Avg"] = [math]::Round($avg, 2)
                    $row["$($def.Code)_Max"] = [math]::Round($max, 2)
                }
                else {
                    $row["$($def.Code)_Avg"] = $null
                    $row["$($def.Code)_Max"] = $null
                    $missingMetrics.Add($def.Code)
                }
            }

            if (-not $performanceInstance -and $availableInstances.Count -eq 0) {
                $row['DataStatus'] = 'No per-disk samples returned; check VM power state and vCenter statistics level.'
            }
            elseif (-not $performanceInstance) {
                $row['DataStatus'] = "Could not map performance instances: $($availableInstances -join ', ')"
            }
            elseif ($missingMetrics.Count -gt 0) {
                $row['DataStatus'] = "Missing counters: $($missingMetrics -join ', ')"
            }
            else {
                $row['DataStatus'] = 'OK'
            }

            [PSCustomObject]$row
        }
    }

    $diskColumnMap = [ordered]@{
        'size (In GB)'                              = 'CapacityGB'
        'read throughput average (MB per second)'   = 'ReadThroughput_MBps_Avg'
        'read throughput maximum (MB per second)'   = 'ReadThroughput_MBps_Max'
        'write throughput average (MB per second)'  = 'WriteThroughput_MBps_Avg'
        'write throughput maximum (MB per second)'  = 'WriteThroughput_MBps_Max'
        'read ops average (operations per second)'  = 'ReadIOPS_Avg'
        'read ops maximum (operations per second)'  = 'ReadIOPS_Max'
        'write ops average (operations per second)' = 'WriteIOPS_Avg'
        'write ops maximum (operations per second)' = 'WriteIOPS_Max'
        'data status'                               = 'DataStatus'
    }
    $maxDiskNumber = [int](($diskSummaryRows | Measure-Object -Property DiskNumber -Maximum).Maximum)

    foreach ($summaryRow in @($summaryRows)) {
        for ($diskNumber = 1; $diskNumber -le $maxDiskNumber; $diskNumber++) {
            $diskRow = $diskSummaryRows | Where-Object {
                $_.VMName -eq $summaryRow.'Server name' -and $_.DiskNumber -eq $diskNumber
            } | Select-Object -First 1

            foreach ($column in $diskColumnMap.GetEnumerator()) {
                $columnName = "Disk $diskNumber $($column.Key)"
                $columnValue = if ($diskRow) { $diskRow.($column.Value) } else { $null }
                $summaryRow | Add-Member -NotePropertyName $columnName -NotePropertyValue $columnValue -Force
            }
        }
    }

    $summaryRows | Export-Csv -Path $summaryPath -NoTypeInformation

    Write-Host ""
    Write-Host "=== Collection complete ===" -ForegroundColor Cyan
    Write-Host "VMs processed        : $($targetVMs.Count)"
    Write-Host "Virtual disks        : $(@($diskSummaryRows).Count)"
    $noDataVMs = @($targetVMs.Name | Where-Object { -not $vmsWithData.Contains($_) })
    if ($noDataVMs.Count -gt 0) {
        Write-Warning "$($noDataVMs.Count) VM(s) returned no performance data at all: $($noDataVMs -join ', ')"
    }
    if ($batchErrorCount -gt 0) {
        Write-Warning "$batchErrorCount batch request(s) failed during collection (see warnings above)."
    }
    if ($perDiskCollectionErrorCount -gt 0) {
        Write-Warning "$perDiskCollectionErrorCount per-disk request(s) failed; check the Disk N data status columns."
    }
    $disksWithoutCompleteData = @($diskSummaryRows | Where-Object { $_.DataStatus -ne 'OK' })
    if ($disksWithoutCompleteData.Count -gt 0) {
        Write-Warning "$($disksWithoutCompleteData.Count) virtual disk(s) have incomplete performance data; see the Disk N data status columns."
    }
    Write-Host "Summary CSV          : $summaryPath"
    Write-Host ""
    Write-Host "Top 10 VMs by average CPU utilization:" -ForegroundColor Cyan
    $summaryRows | Sort-Object -Property 'CPU utilization percentage average' -Descending |
    Select-Object -First 10 'Server name', 'CPU utilization percentage average', 'Memory utilization percentage average', 'Network In throughput average (MB per second)', 'Network Out throughput average (MB per second)' |
    Format-Table -AutoSize | Out-String | Write-Host
}
finally {
    if ($viConnection) {
        Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Disconnected from $VCenterServer."
    }
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
