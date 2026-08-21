# Infrastructure Discovery Collectors

This repository contains three discovery collectors:

- `Get-VMwareUtilizationStats.ps1` for VMware VM utilization and Azure Migrate import shaping.
- `Get-WindowsServerInventory.ps1` for Windows Server role, feature, service, software, task, and certificate inventory.
- `Get-SQLServer2016Stats.sql` for SQL Server estate, dependency, SSIS, and SSRS discovery.

The VMware collector writes CSV outputs from vCenter or a standalone ESXi host.

It is intended for discovery and planning work, such as understanding how busy VMs have been before sizing or migration decisions.

For a beginner-friendly explanation of ESXi, performance samples, and the real-time data limit, see [ESXi Performance Data in Simple Terms](README-ESXI-BASICS.md).

## What It Collects

The script collects common VM performance metrics, including:

- CPU usage
- Memory usage
- Disk reads and writes
- Disk throughput
- Network throughput

It also creates a per-virtual-disk report containing each disk's configured size, read and write throughput, and read and write operations per second (IOPS).

It summarizes the results per VM.

## Historical vs Real-Time

This script has two different ways to collect data.

### Historical Mode

Historical mode is the normal mode for discovery work.

Use this when you want to look back over days or weeks, for example the last 14 days.

In historical mode, the script uses:

- `-Days`
- `-StartDate`
- `-EndDate`

Example:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -Days 14
```

Or with explicit dates:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -StartDate "2026-07-25" `
  -EndDate "2026-08-08"
```

Historical mode can go back further, but the data is usually rolled up by vCenter. That means older data is less detailed than recent data.

For example, vCenter may keep recent samples at a finer interval, then older samples at 30-minute, 2-hour, or daily intervals depending on the vCenter statistics retention settings.

### Real-Time Mode

Real-time mode is for the most recent short window of data.

Use this when you want to see what is happening right now, or very recently.

In real-time mode, the script uses:

- `-Realtime`
- `-RealtimeMinutes`

Example:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -Realtime `
  -RealtimeMinutes 30
```

This means "collect the most recent real-time samples from the last 30 minutes."

It does not mean "collect real-time samples from any date in the past."

For example, you usually cannot ask VMware for real-time samples from two weeks ago. If you need two weeks of data, use historical mode instead.

When connected directly to a standalone ESXi host, the script automatically uses real-time mode because standalone ESXi does not provide the same historical rollup data as vCenter.

### Why Standalone ESXi Cannot Provide 14 Days

In plain terms, a standalone ESXi host keeps performance data like a small, reusable notepad. It records recent activity for roughly the last hour, then overwrites the oldest entries as new ones arrive. It does not keep a long-term performance archive.

vCenter acts as that archive. It regularly collects performance data from ESXi hosts, summarizes it, and stores it so the script can look back over days or weeks.

This means that when the script connects directly to a standalone ESXi host:

- `-Days 14` cannot return 14 days of performance data because the host did not retain it.
- The script automatically collects the available recent real-time data instead, normally up to 60 minutes.
- The missing historical data cannot be recovered after it has been overwritten.

To collect data over 14 days, connect the script to a vCenter Server that manages the host. If vCenter is not available, run the collector regularly and keep each CSV, or send the metrics to an external monitoring system.

## Which Mode Should I Use?

For most discovery or migration planning:

```text
Use historical mode.
```

For a quick current snapshot:

```text
Use real-time mode.
```

Simple rule:

```text
Looking back over days or weeks? Use -Days, -StartDate, and -EndDate.
Looking at what is happening right now? Use -Realtime and -RealtimeMinutes.
```

## Important Parameters

### VCenterServer

The vCenter Server or standalone ESXi host to connect to.

```powershell
-VCenterServer "vcenter.example.com"
```

### Days

How many days of historical data to collect, ending at `-EndDate`.

Default:

```powershell
-Days 14
```

If you provide `-StartDate`, then `-Days` is ignored.

### StartDate and EndDate

Use these when you want a specific historical collection window.

Example:

```powershell
-StartDate "2026-07-25" -EndDate "2026-08-08"
```

These are used for historical mode. They are ignored when `-Realtime` is used.

### Realtime

Tells the script to collect recent real-time samples instead of historical rollups.

Example:

```powershell
-Realtime
```

Use this only when you want a recent snapshot.

### RealtimeMinutes

Controls how many minutes of recent real-time samples to retrieve.

Default:

```powershell
-RealtimeMinutes 60
```

Allowed range:

```text
1 to 60 minutes
```

This does not make the script run for 60 minutes. It asks VMware for the latest retained real-time samples, up to that many minutes back.

### AzureMigrateCsv

Emits an additional file named `AzureMigrateImport.csv` using the Azure Migrate server-import style columns.

Example:

```powershell
-AzureMigrateCsv
```

The mapping is deliberate:

- Single-value utilization fields use the configured percentile (default P95).
- Peak fields use the window maximum.

Memory caveat for sizing:

- `Memory utilization percentage` and `Peak memory utilization percentage` in `AzureMigrateImport.csv` are sourced from VMware active memory (`mem.usage.average`), not guest-consumed memory.
- These values are commonly lower than in-guest telemetry (for example New Relic) by design; the two sources are not directly comparable.
- For sizing context, use the `Memory consumed average (MB)`, `Memory consumed maximum (MB)`, and `Memory consumed P<Percentile> (MB)` columns in `UtilizationSummary.csv` and/or guest-level counters.
- `UtilizationSummary.csv` now also includes current guest-memory counters from VMware Tools telemetry: `Guest memory usage current (MB)` and `Guest memory usage current percentage` (point-in-time values, not window percentiles).

This avoids manual average-vs-maximum choices during import preparation.

### Percentile

Controls which percentile is used for P-columns and Azure Migrate single-value fields.

Default:

```powershell
-Percentile 95
```

### BatchSize

Controls how many VMs are included in each `Get-Stat` query.

Default:

```powershell
-BatchSize 15
```

This does not limit the total number of VMs the script can process.

For example, if there are 60 VMs and `BatchSize` is 15, the script queries them like this:

```text
Batch 1: VMs 1-15
Batch 2: VMs 16-30
Batch 3: VMs 31-45
Batch 4: VMs 46-60
```

The reason for batching is to avoid asking vCenter for too much data in one large request. Smaller batches are gentler on vCenter but may take longer. Larger batches may finish faster but can be heavier.

The allowed range is:

```text
1 to 100
```

The default value of 15 is conservative and suitable for most discovery runs.

### VMName

Limits collection to one or more VM names or name patterns.

Example:

```powershell
-VMName "APP-*"
```

### ClusterName

Limits collection to one or more clusters.

Example:

```powershell
-ClusterName "Production-Cluster"
```

## Output

The script writes results to an output folder.

If you do not provide `-OutputFolder`, it creates a timestamped folder beside the script, for example:

```text
VMwareUtilizationReport_20260808_002808
```

The main files are:

- `UtilizationSummary.csv`
- `CollectionLog.txt`

### Raw Samples Evidence Export

If you include `-IncludeRawSamples`, the script also writes `RawSamples.csv`.

This file contains each retained sample point returned by VMware, including:

- VM name
- Metric ID
- UTC timestamp
- Sample interval in seconds
- Raw value and converted value
- Disk instance (for per-disk counters)
- Segment metadata

Use this file as an evidence trail when validating percentile values in the summary.

### Percentile Behavior and Limitation

The script computes percentile columns (for example P95) using the nearest-rank method over all retained samples in the selected collection window.

Important limitation:

- In standalone ESXi mode, percentiles are computed from the short retained real-time window only (normally about the last 60 minutes).
- In vCenter historical mode, percentiles are computed from whichever rollup intervals vCenter currently retains for the requested time range. This can include mixed sample granularity (finer for recent data, coarser for older data).

So P95 always reflects the best available retained data for that window, but it is not equivalent to continuous fine-grained raw telemetry over long periods when only rolled-up history is available.

### Per-Disk Output

Per-disk inventory and performance are included in `UtilizationSummary.csv`, so each VM and all of its disks appear on one CSV row.

The script checks the largest number of disks attached to the selected VMs and creates a matching set of columns. For example, if any VM has two disks, every VM row receives `Disk 1 ...` and `Disk 2 ...` columns. A VM with only one disk has empty `Disk 2 ...` fields.

The columns for each disk include average and maximum read/write throughput and operations per second. For example:

- `Disk 1 size (In GB)`
- `Disk 1 read throughput average (MB per second)`
- `Disk 1 read throughput maximum (MB per second)`
- `Disk 1 write throughput average (MB per second)`
- `Disk 1 write throughput maximum (MB per second)`
- `Disk 1 read ops average (operations per second)`
- `Disk 1 read ops maximum (operations per second)`
- `Disk 1 write ops average (operations per second)`
- `Disk 1 write ops maximum (operations per second)`
- `Disk 1 data status`

The same pattern continues with `Disk 2`, `Disk 3`, and so on. Disk names, controller addresses, performance-instance identifiers, and disk sample counts are not exported.

Per-disk historical counters require vCenter to retain per-device statistics. If the configured vCenter statistics level does not retain those counters, the disk inventory and sizes will still appear, but the performance fields may be empty and the disk data-status column will explain why. Standalone ESXi uses its recent real-time counters instead.

### Azure Migrate Export

If you include `-AzureMigrateCsv`, the script writes `AzureMigrateImport.csv` in the same output folder.

This export is intended to match Azure Migrate import expectations by avoiding average/maximum column pairs for single-value utilization fields.

Field selection policy:

- `CPU utilization percentage`, `Memory utilization percentage`, and network throughput single-value columns are populated from `P<Percentile>` (default P95).
- `Peak ...` columns are populated from window maximum values.

### Summary Column Order

The server-level columns are exported in this order:

1. `Server name`
2. `Cluster`
3. `IP addresses`
4. `PowerState`
5. `Cores`
6. `Memory (In MB)`
7. `Guest memory usage current (MB)`
8. `Guest memory usage current percentage`
9. `OS name`
10. `OS version`
11. `OS architecture`
12. `Server type`
13. `Hypervisor`
14. CPU utilization average and maximum
15. Memory active percentage average and maximum, plus memory consumed average and maximum (MB)
16. `Network adapters`
17. Network In throughput average and maximum
18. Network Out throughput average and maximum
19. `Boot Type`
20. `Number of disks`
21. `Storage in use (In GB)`
22. The repeating `Disk 1`, `Disk 2`, and later disk columns

Guest IP addresses, the running OS name/version, and some architecture details depend on VMware Tools reporting data from inside the VM. If VMware Tools is unavailable, the script falls back to the OS configured on the VM where possible, and unavailable optional fields remain empty.

## Common Examples

Collect the last 14 days from vCenter:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -Days 14
```

Collect a specific two-week period:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -StartDate "2026-07-25" `
  -EndDate "2026-08-08"
```

Collect only VMs in one cluster:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -ClusterName "Production-Cluster" `
  -Days 14
```

Collect a recent real-time snapshot:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -Realtime `
  -RealtimeMinutes 30
```

Collect from a standalone ESXi host and export raw samples for P95 validation:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "esxi-host.example.com" `
  -RealtimeMinutes 60 `
  -IncludeRawSamples `
  -Percentile 95 `
  -AllowSelfSignedCertificate `
  -OutputFolder ".\ExampleOutputs\VMwareUtilizationStats"
```

Notes:

- Standalone ESXi automatically uses real-time mode.
- This command creates both `UtilizationSummary.csv` and `RawSamples.csv` in the output folder.
- P95 values are computed from the retained real-time sample window returned by the host.

Collect from a standalone ESXi host and also emit Azure Migrate import CSV:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "esxi-host.example.com" `
  -RealtimeMinutes 60 `
  -Percentile 95 `
  -AzureMigrateCsv `
  -AllowSelfSignedCertificate `
  -OutputFolder ".\ExampleOutputs\VMwareUtilizationStats"
```

This command emits:

- `UtilizationSummary.csv`
- `AzureMigrateImport.csv`
- `CollectionLog.txt`

## VMware Script Requirements

You need:

- PowerShell
- VMware PowerCLI
- Read-only access to vCenter or ESXi

If VMware PowerCLI is not installed, the script can prompt to install it. You can also allow automatic installation with:

```powershell
-AutoInstallPowerCLI
```

If your client server cannot install directly from PSGallery (for example change-control, proxy, or offline environments), stage PowerCLI offline:

On an internet-connected staging machine:

```powershell
Save-Module -Name VMware.PowerCLI -Path C:\Temp\PowerCLI -Force
```

Copy the saved module folder to the target server under your user module path (for example `%USERPROFILE%\Documents\PowerShell\Modules\`).

Then verify on the target server:

```powershell
Get-Module -ListAvailable VMware.VimAutomation.Core
```

After offline staging is complete, run the script without `-AutoInstallPowerCLI`.

If your vCenter or ESXi host uses a self-signed certificate, you may need:

```powershell
-AllowSelfSignedCertificate
```

## Windows Server Inventory Script

Script: `Get-WindowsServerInventory.ps1`

### Required Access

- **Local administrator** on each target server — required to enumerate all Windows services (`Win32_Service`), `LocalMachine` certificate stores, and the full `Uninstall` registry hive.
- WinRM must be reachable from the collection host (HTTP port 5985 by default; HTTPS port 5986 with `-UseSSL`).
- The script makes no changes; it is read-only on the target.

### How To Run

By server name list:

```powershell
.\Get-WindowsServerInventory.ps1 `
  -ServerName "server01","server02" `
  -OutputFolder ".\ExampleOutputs\WindowsServerInventory"
```

By text file:

```powershell
.\Get-WindowsServerInventory.ps1 `
  -ServerListFile ".\servers.txt" `
  -UseSSL `
  -Authentication Kerberos `
  -OutputFolder ".\ExampleOutputs\WindowsServerInventory"
```

### Expected Outputs

- `InventorySummary.csv`
- `Roles.csv`
- `Features.csv`
- `Services.csv`
- `InstalledApplications.csv`
- `ScheduledTasks.csv`
- `Certificates.csv`
- `CollectionErrors.csv`
- `CollectionLog.txt`

### Data Sensitivity

These outputs can contain sensitive operational information such as service accounts, installed software inventory, scheduled-task actions, certificate subjects/SANs/thumbprints, and server names.

## SQL Server Discovery Script

Script: `Get-SQLServer2016Stats.sql`

### Required Access (Read-Only Scope)

- SQL login with CONNECT rights to the SQL Server instance.
- Server-level permission: VIEW SERVER STATE.
- Read access to system metadata queried by this script in:
  - master (server metadata and linked-server metadata).
  - msdb (sysjobs, sysjobsteps, sysssispackages).
  - SSISDB when present (catalog views for package inventory and execution history).
  - ReportServer or ReportServer$INSTANCE when present (Catalog, Subscriptions, ExecutionLog3).
- For AG metadata, the same VIEW SERVER STATE permission is required.
- Optional for FQDN enrichment only: permission to execute master.dbo.xp_regread. If unavailable, the script falls back to machine name.
- The script performs discovery reads only; it does not modify data.

Practical role mapping for a read-only account:

- Instance-level: VIEW SERVER STATE.
- msdb: SQLAgentReaderRole (or equivalent SELECT access to dbo.sysjobs and dbo.sysjobsteps).
- SSISDB (if used): ssis_logreader role or equivalent SELECT on catalog views.
- ReportServer database(s) (if used): db_datareader.

### How To Run

In SSMS:

- Open `Get-SQLServer2016Stats.sql`.
- Connect to the target SQL Server instance.
- Execute and save the single result set to CSV (for example `SqlSummary.csv`).
- Prefer Results to Text or direct file export. Copying from grid can mangle multi-line list fields.

With sqlcmd:

```powershell
sqlcmd -S "sqlhost\instance" -E -i ".\Get-SQLServer2016Stats.sql" -s "," -W -h-1 -o ".\ExampleOutputs\SQLServer2016Stats\SqlSummary.csv"
```

With Invoke-SqlCmd (PowerShell):

```powershell
$rows = Invoke-SqlCmd -ServerInstance "sqlhost\instance" -InputFile ".\Get-SQLServer2016Stats.sql" -ErrorAction Stop
$rows | Export-Csv -Path ".\ExampleOutputs\SQLServer2016Stats\SqlSummary.csv" -NoTypeInformation -Encoding UTF8
```

Using sqlcmd or Invoke-SqlCmd avoids SSMS grid copy issues with long or multi-line columns.

### Expected Output

- One tabular result set (typically exported as `SqlSummary.csv`) containing server, database, storage, linked-server dependency, SSIS, and SSRS discovery fields.

Linked-server dependency caveat:

- `Linked server dependency count` and `Linked server dependencies` are lower-bound discovery results.
- They capture static metadata-visible dependencies (for example four-part-name references in SQL objects).
- Dynamic SQL and application-side linked-server usage are not fully visible to this script.

### AG Node Aggregation Note

If you run the SQL script on every Availability Group node, each node can return rows for the same production database. To avoid double-counting database sizes in estate rollups:

- Use the `Replica type` column and aggregate AG database size metrics from primary rows only (`PRIMARY`).
- Alternatively deduplicate by availability-group/database identity before summing capacity.

### Data Sensitivity

This output can include linked-server names, dependency paths, SSIS package names, SQL Agent job names, SSRS report paths, listener names/IPs, and database/file layout.

## Example Output Folder Layout

Current repository layout keeps one top-level example folder with one subfolder per collector:

```text
ExampleOutputs/
  VMwareUtilizationStats/
  WindowsServerInventory/
  SQLServer2016Stats/
```

`SQLServer2016Stats` may be empty until you export a `SqlSummary.csv` from SSMS or sqlcmd.

## Plain-English Summary

Use this script to collect VM utilization data from VMware.

For migration or discovery work, use historical mode with `-Days`, `-StartDate`, and `-EndDate`.

Use `-Realtime` only when you want a current snapshot from the recent real-time window.

`BatchSize` controls how many VMs are queried at once. It does not limit how many VMs the script can collect overall.
