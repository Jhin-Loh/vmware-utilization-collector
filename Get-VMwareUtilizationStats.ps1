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

    [Parameter(HelpMessage = "Also export every individual raw sample (large output) in addition to the per-VM summary.")]
    [switch]$IncludeRawSamples,

    [Parameter(HelpMessage = "Number of VMs to query per Get-Stat call.")]
    [ValidateRange(1, 100)]
    [int]$BatchSize = 15,

    [Parameter(HelpMessage = "Collect retained real-time samples instead of historical rollups. Standalone ESXi always uses real-time mode.")]
    [switch]$Realtime,

    [Parameter(HelpMessage = "Maximum recent real-time window to retrieve in real-time mode.")]
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
                    IntervalMins = [int]($iv.SamplingPeriod / 60)
                    SampleIntervalSeconds = [int]$iv.SamplingPeriod
                    Level        = $iv.Level
                    Start        = $segmentStart
                    Finish       = $cursor
                })
            $cursor = $segmentStart
        }
    }

    return @($plan | Sort-Object Start)
}

function Get-Percentile {
    [CmdletBinding()]
    param(
        $Values,
        [double]$Percentile = 95
    )
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [int][math]::Ceiling(($Percentile / 100) * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return $sorted[$index]
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

$StatDefinitions = @(
    [PSCustomObject]@{ Code = 'CPU_Pct'; MetricId = 'cpu.usage.average'; RollupType = 'average'; Factor = 1; DisplayUnit = '%' }
    [PSCustomObject]@{ Code = 'CPU_MHz'; MetricId = 'cpu.usagemhz.average'; RollupType = 'average'; Factor = 1; DisplayUnit = 'MHz' }
    [PSCustomObject]@{ Code = 'Mem_Pct'; MetricId = 'mem.usage.average'; RollupType = 'average'; Factor = 1; DisplayUnit = '%' }
    [PSCustomObject]@{ Code = 'MemConsumed_GB'; MetricId = 'mem.consumed.average'; RollupType = 'average'; Factor = (1 / 1MB); DisplayUnit = 'GB' }
    [PSCustomObject]@{ Code = 'MemActive_GB'; MetricId = 'mem.active.average'; RollupType = 'average'; Factor = (1 / 1MB); DisplayUnit = 'GB' }
    [PSCustomObject]@{ Code = 'DiskReadIOPS'; MetricId = 'disk.numberread.summation'; RollupType = 'summation'; Factor = 1; DisplayUnit = 'IOPS' }
    [PSCustomObject]@{ Code = 'DiskWriteIOPS'; MetricId = 'disk.numberwrite.summation'; RollupType = 'summation'; Factor = 1; DisplayUnit = 'IOPS' }
    [PSCustomObject]@{ Code = 'DiskThroughput_KBps'; MetricId = 'disk.usage.average'; RollupType = 'average'; Factor = 1; DisplayUnit = 'KBps' }
    [PSCustomObject]@{ Code = 'NetThroughput_KBps'; MetricId = 'net.usage.average'; RollupType = 'average'; Factor = 1; DisplayUnit = 'KBps' }
    [PSCustomObject]@{ Code = 'NetTransmit_KBps'; MetricId = 'net.transmitted.average'; RollupType = 'average'; Factor = 1; DisplayUnit = 'KBps' }
    [PSCustomObject]@{ Code = 'NetReceive_KBps'; MetricId = 'net.received.average'; RollupType = 'average'; Factor = 1; DisplayUnit = 'KBps' }
)
$StatIds = $StatDefinitions.MetricId
$StatDefLookup = @{}
foreach ($d in $StatDefinitions) { $StatDefLookup[$d.MetricId] = $d }

#endregion Metric definitions

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
    $targetVMs = @(Get-VM @vmParams -ErrorAction Stop)
    if (-not $IncludePoweredOffVMs) {
        $targetVMs = @($targetVMs | Where-Object { $_.PowerState -eq 'PoweredOn' })
    }
    if ($targetVMs.Count -eq 0) {
        throw "No VMs matched the requested scope (ClusterName/VMName/power state filters)."
    }
    Write-Host "Target VM scope: $($targetVMs.Count) VM(s)."

    # Build a VMHost -> Cluster lookup once, to avoid a per-VM Get-Cluster call
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

    # Real-time samples are short-retention data (normally 20-second granularity). Historical
    # mode uses vCenter's retained rollup intervals for multi-day or multi-week windows.

    $summaryAccumulator = @{}
    $vmsWithData = [System.Collections.Generic.HashSet[string]]::new()
    $rawExportPath = Join-Path $OutputFolder 'RawSamples.csv'

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
                    $statResults = Get-Stat -Entity $batch -Stat $StatIds -Realtime -MaxSamples $segment.MaxSamples `
                        -Instance '' -Server $viConnection -ErrorAction Stop
                }
                else {
                    $statResults = Get-Stat -Entity $batch -Stat $StatIds -Start $segment.Start -Finish $segment.Finish `
                        -IntervalMins $segment.IntervalMins -Instance '' -Server $viConnection -ErrorAction Stop
                }
            }
            catch {
                Write-Warning "Batch $batchIndex ($($segment.Start) -> $($segment.Finish)) failed: $($_.Exception.Message)"
                $batchErrorCount++
                continue
            }

            if (-not $statResults) { continue }

            if ($IncludeRawSamples) {
                $statResults | Select-Object Entity, Timestamp, MetricId, Value, Unit, Instance |
                Export-Csv -Path $rawExportPath -Append -NoTypeInformation
            }

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
        }
    }
    Write-Progress -Activity "Collecting VMware utilization statistics" -Completed

    # Build the per-VM summary (Avg / Max / 95th percentile per metric)
    $summaryRows = foreach ($vm in $targetVMs) {
        $row = [ordered]@{
            VMName        = $vm.Name
            Cluster       = if ($isStandaloneEsxi) { '(standalone ESXi)' } elseif ($clusterMap.ContainsKey($vm.VMHost.Name)) { $clusterMap[$vm.VMHost.Name] } else { '(unknown)' }
            VMHost        = $vm.VMHost.Name
            PowerState    = $vm.PowerState.ToString()
            NumCPU        = $vm.NumCpu
            MemoryGB      = [math]::Round($vm.MemoryGB, 2)
            ProvisionedGB = [math]::Round($vm.ProvisionedSpaceGB, 2)
        }

        foreach ($def in $StatDefinitions) {
            $key = "$($vm.Name)|$($def.MetricId)"
            $values = $summaryAccumulator[$key]

            if ($values -and $values.Count -gt 0) {
                $avg = ([double](($values | Measure-Object -Average).Average)) * $def.Factor
                $max = ([double](($values | Measure-Object -Maximum).Maximum)) * $def.Factor
                $p95 = ([double](Get-Percentile -Values $values -Percentile 95)) * $def.Factor

                $row["$($def.Code)_Avg"] = [math]::Round($avg, 2)
                $row["$($def.Code)_Max"] = [math]::Round($max, 2)
                $row["$($def.Code)_P95"] = [math]::Round($p95, 2)

                if ($def.MetricId -eq 'cpu.usage.average') {
                    $row['SampleCount'] = $values.Count
                }
            }
            else {
                $row["$($def.Code)_Avg"] = $null
                $row["$($def.Code)_Max"] = $null
                $row["$($def.Code)_P95"] = $null
            }
        }

        if ($null -ne $row['DiskReadIOPS_Avg'] -and $null -ne $row['DiskWriteIOPS_Avg']) {
            $row['DiskTotalIOPS_Avg'] = [math]::Round($row['DiskReadIOPS_Avg'] + $row['DiskWriteIOPS_Avg'], 2)
        }
        else {
            $row['DiskTotalIOPS_Avg'] = $null
        }

        [PSCustomObject]$row
    }

    $summaryPath = Join-Path $OutputFolder 'UtilizationSummary.csv'
    $summaryRows | Export-Csv -Path $summaryPath -NoTypeInformation

    Write-Host ""
    Write-Host "=== Collection complete ===" -ForegroundColor Cyan
    Write-Host "VMs processed        : $($targetVMs.Count)"
    $noDataVMs = @($targetVMs.Name | Where-Object { -not $vmsWithData.Contains($_) })
    if ($noDataVMs.Count -gt 0) {
        Write-Warning "$($noDataVMs.Count) VM(s) returned no performance data at all: $($noDataVMs -join ', ')"
    }
    if ($batchErrorCount -gt 0) {
        Write-Warning "$batchErrorCount batch request(s) failed during collection (see warnings above)."
    }
    Write-Host "Summary CSV          : $summaryPath"
    if ($IncludeRawSamples) {
        Write-Host "Raw samples CSV      : $rawExportPath"
    }
    Write-Host ""
    Write-Host "Top 10 VMs by average CPU utilization:" -ForegroundColor Cyan
    $summaryRows | Sort-Object -Property CPU_Pct_Avg -Descending |
    Select-Object -First 10 VMName, CPU_Pct_Avg, Mem_Pct_Avg, DiskTotalIOPS_Avg, NetThroughput_KBps_Avg |
    Format-Table -AutoSize | Out-String | Write-Host
}
finally {
    if ($viConnection) {
        Disconnect-VIServer -Server $viConnection -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Disconnected from $VCenterServer."
    }
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
