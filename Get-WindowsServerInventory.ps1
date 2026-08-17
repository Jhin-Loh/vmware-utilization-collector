[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true, HelpMessage = "One or more server hostnames or FQDNs.")]
    [string[]]$ServerName,

    [Parameter(ParameterSetName = 'ByFile', Mandatory = $true, HelpMessage = "Path to a text file containing one server hostname/FQDN per line. Blank lines and lines starting with # are ignored.")]
    [string]$ServerListFile,

    [Parameter(HelpMessage = "Credential to use for remoting. If omitted, the current user's credentials are used.")]
    [PSCredential]$Credential,

    [Parameter(HelpMessage = "Folder to write CSVs and run log to.")]
    [string]$OutputFolder,

    [Parameter(HelpMessage = "Maximum number of servers queried in parallel.")]
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 8,

    [Parameter(HelpMessage = "Per-server remoting timeout in seconds.")]
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 300,

    [Parameter(HelpMessage = "Certificate stores to enumerate. Defaults to LocalMachine\\My and LocalMachine\\WebHosting (the stores where server/IIS/code-signing certs live).")]
    [string[]]$CertificateStore = @('My', 'WebHosting', 'Root', 'CA', 'TrustedPublisher')
)

if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $OutputFolder = Join-Path -Path $PSScriptRoot -ChildPath "WindowsServerInventory_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

function Resolve-TargetList {
    [CmdletBinding()]
    param(
        [string[]]$ServerName,
        [string]$ServerListFile
    )

    if ($ServerName) {
        return @($ServerName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    }

    if (-not (Test-Path -LiteralPath $ServerListFile)) {
        throw "Server list file '$ServerListFile' does not exist."
    }

    return @(Get-Content -LiteralPath $ServerListFile |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*' } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique)
}

# Runs on each remote server; returns tagged PSCustomObjects grouped by category so the driver can split them into per-category CSVs.
$RemoteInventoryScriptBlock = {
    param(
        [string[]]$CertificateStore
    )

    $ErrorActionPreference = 'Continue'
    $server = $env:COMPUTERNAME
    $results = [System.Collections.Generic.List[object]]::new()

    # Roles & Features (Server Manager)
    try {
        Import-Module ServerManager -ErrorAction Stop
        foreach ($feature in (Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed })) {
            $results.Add([PSCustomObject]@{
                    Category    = if ($feature.FeatureType -eq 'Role') { 'Role' } else { 'Feature' }
                    ServerName  = $server
                    Name        = $feature.Name
                    DisplayName = $feature.DisplayName
                    FeatureType = [string]$feature.FeatureType
                    Path        = $feature.Path
                    Depth       = $feature.Depth
                    Parent      = $feature.Parent
                })
        }
    }
    catch {
        $results.Add([PSCustomObject]@{
                Category   = 'CollectionError'
                ServerName = $server
                Area       = 'RolesAndFeatures'
                Message    = $_.Exception.Message
            })
    }

    # Services
    try {
        foreach ($svc in (Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
            $results.Add([PSCustomObject]@{
                    Category    = 'Service'
                    ServerName  = $server
                    Name        = $svc.Name
                    DisplayName = $svc.DisplayName
                    State       = $svc.State
                    StartMode   = $svc.StartMode
                    StartName   = $svc.StartName
                    PathName    = $svc.PathName
                    Description = $svc.Description
                })
        }
    }
    catch {
        $results.Add([PSCustomObject]@{
                Category   = 'CollectionError'
                ServerName = $server
                Area       = 'Services'
                Message    = $_.Exception.Message
            })
    }

    # Installed Applications
    try {
        $uninstallKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        foreach ($root in $uninstallKeys) {
            if (-not (Test-Path -LiteralPath $root)) { continue }

            $architecture = if ($root -match 'WOW6432Node') { 'x86' } else { 'x64' }

            foreach ($entry in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { continue }
                if ([string]::IsNullOrWhiteSpace($props.DisplayName)) { continue }
                # SystemComponent = 1 marks OS/update entries, not user-visible apps.
                if ($props.SystemComponent -eq 1) { continue }

                $results.Add([PSCustomObject]@{
                        Category        = 'InstalledApplication'
                        ServerName      = $server
                        DisplayName     = $props.DisplayName
                        DisplayVersion  = $props.DisplayVersion
                        Publisher       = $props.Publisher
                        InstallDate     = $props.InstallDate
                        InstallLocation = $props.InstallLocation
                        UninstallString = $props.UninstallString
                        Architecture    = $architecture
                    })
            }
        }
    }
    catch {
        $results.Add([PSCustomObject]@{
                Category   = 'CollectionError'
                ServerName = $server
                Area       = 'InstalledApplications'
                Message    = $_.Exception.Message
            })
    }

    # Scheduled tasks
    try {
        foreach ($task in (Get-ScheduledTask -ErrorAction Stop)) {
            $taskInfo = $null
            try { $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop } catch {}

            $actions = @($task.Actions | ForEach-Object {
                    if ($_.PSObject.Properties['Execute']) { $_.Execute }
                    elseif ($_.PSObject.Properties['Uri']) { $_.Uri }
                    else { $_.GetType().Name }
                }) -join '; '

            $principal = $null
            try { $principal = $task.Principal.UserId } catch {}

            $results.Add([PSCustomObject]@{
                    Category    = 'ScheduledTask'
                    ServerName  = $server
                    TaskPath    = $task.TaskPath
                    TaskName    = $task.TaskName
                    State       = [string]$task.State
                    RunAs       = $principal
                    Actions     = $actions
                    LastRunTime = if ($taskInfo) { $taskInfo.LastRunTime } else { $null }
                    LastResult  = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
                    NextRunTime = if ($taskInfo) { $taskInfo.NextRunTime } else { $null }
                    Author      = $task.Author
                    Description = $task.Description
                })
        }
    }
    catch {
        $results.Add([PSCustomObject]@{
                Category   = 'CollectionError'
                ServerName = $server
                Area       = 'ScheduledTasks'
                Message    = $_.Exception.Message
            })
    }

    # Certificates
    foreach ($storeName in $CertificateStore) {
        $storePath = "Cert:\LocalMachine\$storeName"
        try {
            if (-not (Test-Path -LiteralPath $storePath)) { continue }
            foreach ($cert in (Get-ChildItem -LiteralPath $storePath -ErrorAction Stop)) {
                $eku = @()
                try {
                    $eku = $cert.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }
                }
                catch {}
                $sans = $null
                try {
                    $sanExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
                    if ($sanExt) { $sans = $sanExt.Format($false) }
                }
                catch {}

                $results.Add([PSCustomObject]@{
                        Category         = 'Certificate'
                        ServerName       = $server
                        Store            = $storeName
                        Subject          = $cert.Subject
                        Issuer           = $cert.Issuer
                        NotBefore        = $cert.NotBefore
                        NotAfter         = $cert.NotAfter
                        Thumbprint       = $cert.Thumbprint
                        HasPrivateKey    = $cert.HasPrivateKey
                        FriendlyName     = $cert.FriendlyName
                        EnhancedKeyUsage = ($eku -join '; ')
                        SubjectAltNames  = $sans
                    })
            }
        }
        catch {
            $results.Add([PSCustomObject]@{
                    Category   = 'CollectionError'
                    ServerName = $server
                    Area       = "Certificates:$storeName"
                    Message    = $_.Exception.Message
                })
        }
    }

    return $results
}

$targets = Resolve-TargetList -ServerName $ServerName -ServerListFile $ServerListFile
if ($targets.Count -eq 0) {
    throw "No target servers resolved. Provide -ServerName or -ServerListFile with at least one host."
}

New-Item -ItemType Directory -Path $OutputFolder -Force -ErrorAction Stop | Out-Null
Start-Transcript -Path (Join-Path $OutputFolder 'CollectionLog.txt') -ErrorAction SilentlyContinue | Out-Null

try {
    Write-Host "=== Windows Server inventory collection ===" -ForegroundColor Cyan
    Write-Host "Targets       : $($targets.Count)"
    Write-Host "Output folder : $OutputFolder"
    Write-Host "Throttle limit: $ThrottleLimit"
    Write-Host "Timeout       : $TimeoutSeconds seconds per server"
    Write-Host ""

    $invokeParams = @{
        ComputerName  = $targets
        ScriptBlock   = $RemoteInventoryScriptBlock
        ArgumentList  = @(, $CertificateStore)
        ThrottleLimit = $ThrottleLimit
        ErrorAction   = 'Continue'
        ErrorVariable = 'remoteErrors'
    }
    if ($Credential) { $invokeParams['Credential'] = $Credential }

    Write-Host "Invoking remote collection..." -ForegroundColor Cyan
    $rawResults = @()
    try {
        $rawResults = @(Invoke-Command @invokeParams)
    }
    catch {
        Write-Warning "Invoke-Command surfaced an error: $($_.Exception.Message)"
    }

    # Categorize into typed lists
    $byCategory = @{
        Role                 = [System.Collections.Generic.List[object]]::new()
        Feature              = [System.Collections.Generic.List[object]]::new()
        Service              = [System.Collections.Generic.List[object]]::new()
        InstalledApplication = [System.Collections.Generic.List[object]]::new()
        ScheduledTask        = [System.Collections.Generic.List[object]]::new()
        Certificate          = [System.Collections.Generic.List[object]]::new()
        CollectionError      = [System.Collections.Generic.List[object]]::new()
    }
    $reachedServers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $rawResults) {
        if (-not $item) { continue }
        $cat = [string]$item.Category
        if (-not $byCategory.ContainsKey($cat)) { continue }
        $byCategory[$cat].Add($item)
        if ($item.ServerName) { [void]$reachedServers.Add([string]$item.ServerName) }
    }

    # Any WinRM/connection-level failures show up in $remoteErrors, keyed by target computer name.
    $unreachableErrors = @{}
    foreach ($err in @($remoteErrors)) {
        $target = $null
        if ($err.TargetObject) { $target = [string]$err.TargetObject }
        elseif ($err.OriginInfo -and $err.OriginInfo.PSComputerName) { $target = [string]$err.OriginInfo.PSComputerName }
        if (-not $target) { continue }
        $unreachableErrors[$target] = $err.Exception.Message
    }

    # Per-server summary
    $summaryRows = foreach ($t in $targets) {
        $reached = $reachedServers.Contains($t)
        $connectionError = if ($unreachableErrors.ContainsKey($t)) { $unreachableErrors[$t] } else { $null }
        $collectionErrors = @($byCategory['CollectionError'] | Where-Object { $_.ServerName -eq $t })

        [PSCustomObject]@{
            ServerName           = $t
            Reached              = if ($reached) { 'TRUE' } else { 'FALSE' }
            ConnectionError      = $connectionError
            RoleCount            = @($byCategory['Role']                 | Where-Object { $_.ServerName -eq $t }).Count
            FeatureCount         = @($byCategory['Feature']              | Where-Object { $_.ServerName -eq $t }).Count
            ServiceCount         = @($byCategory['Service']              | Where-Object { $_.ServerName -eq $t }).Count
            InstalledAppCount    = @($byCategory['InstalledApplication'] | Where-Object { $_.ServerName -eq $t }).Count
            ScheduledTaskCount   = @($byCategory['ScheduledTask']        | Where-Object { $_.ServerName -eq $t }).Count
            CertificateCount     = @($byCategory['Certificate']          | Where-Object { $_.ServerName -eq $t }).Count
            CollectionErrorAreas = ($collectionErrors | ForEach-Object { $_.Area } | Sort-Object -Unique) -join '; '
        }
    }

    # Emit CSVs
    $exports = [ordered]@{
        'InventorySummary.csv'      = , $summaryRows
        'Roles.csv'                 = $byCategory['Role']
        'Features.csv'              = $byCategory['Feature']
        'Services.csv'              = $byCategory['Service']
        'InstalledApplications.csv' = $byCategory['InstalledApplication']
        'ScheduledTasks.csv'        = $byCategory['ScheduledTask']
        'Certificates.csv'          = $byCategory['Certificate']
        'CollectionErrors.csv'      = $byCategory['CollectionError']
    }
    foreach ($fileName in $exports.Keys) {
        $rows = $exports[$fileName]
        $path = Join-Path $OutputFolder $fileName
        if ($rows -and @($rows).Count -gt 0) {
            # Drop the note properties WinRM adds to every remoted object.
            @($rows) |
                Select-Object -Property * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName |
                Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        }
        else {
            # Keep an empty file so downstream tooling doesn't need to special-case missing outputs.
            Set-Content -Path $path -Value '' -Encoding UTF8
        }
    }

    Write-Host ""
    Write-Host "=== Collection complete ===" -ForegroundColor Cyan
    Write-Host "Targets total       : $($targets.Count)"
    Write-Host "Targets reached     : $($reachedServers.Count)"
    $unreachedCount = $targets.Count - $reachedServers.Count
    if ($unreachedCount -gt 0) {
        Write-Warning "$unreachedCount server(s) could not be reached; see ConnectionError column in InventorySummary.csv."
    }
    $errorRowCount = $byCategory['CollectionError'].Count
    if ($errorRowCount -gt 0) {
        Write-Warning "$errorRowCount per-area collection error(s) recorded; see CollectionErrors.csv."
    }
    Write-Host "Output folder       : $OutputFolder"
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
