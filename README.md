# VMware Utilization Collector

This PowerShell script collects virtual machine utilization statistics from VMware vCenter or a standalone ESXi host and writes the results to CSV files.

It is intended for discovery and planning work, such as understanding how busy VMs have been before sizing or migration decisions.

## What It Collects

The script collects common VM performance metrics, including:

- CPU usage
- Memory usage
- Disk reads and writes
- Disk throughput
- Network throughput

By default, it summarizes the results per VM. You can also choose to export the individual raw samples.

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

### IncludeRawSamples

Exports every individual performance sample in addition to the VM summary.

Example:

```powershell
-IncludeRawSamples
```

This can create a much larger output file.

## Output

The script writes results to an output folder.

If you do not provide `-OutputFolder`, it creates a timestamped folder beside the script, for example:

```text
VMwareUtilizationReport_20260808_002808
```

The main files are:

- `UtilizationSummary.csv`
- `CollectionLog.txt`
- `RawSamples.csv`, only when `-IncludeRawSamples` is used

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

Collect historical data and include raw samples:

```powershell
.\Get-VMwareUtilizationStats.ps1 `
  -VCenterServer "vcenter.example.com" `
  -Days 14 `
  -IncludeRawSamples
```

## Requirements

You need:

- PowerShell
- VMware PowerCLI
- Read-only access to vCenter or ESXi

If VMware PowerCLI is not installed, the script can prompt to install it. You can also allow automatic installation with:

```powershell
-AutoInstallPowerCLI
```

If your vCenter or ESXi host uses a self-signed certificate, you may need:

```powershell
-AllowSelfSignedCertificate
```

## Plain-English Summary

Use this script to collect VM utilization data from VMware.

For migration or discovery work, use historical mode with `-Days`, `-StartDate`, and `-EndDate`.

Use `-Realtime` only when you want a current snapshot from the recent real-time window.

`BatchSize` controls how many VMs are queried at once. It does not limit how many VMs the script can collect overall.
