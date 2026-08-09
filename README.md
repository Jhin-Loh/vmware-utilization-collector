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

It also creates a per-virtual-disk report containing each disk's configured size, read and write throughput, and read and write operations per second (IOPS).

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

### Summary Column Order

The server-level columns are exported in this order:

1. `Server name`
2. `Cluster`
3. `IP addresses`
4. `PowerState`
5. `Cores`
6. `Memory (In MB)`
7. `OS name`
8. `OS version`
9. `OS architecture`
10. `Server type`
11. `Hypervisor`
12. CPU utilization average and maximum
13. Memory utilization average and maximum
14. `Network adapters`
15. Network In throughput average and maximum
16. Network Out throughput average and maximum
17. `Boot Type`
18. `Number of disks`
19. `Storage in use (In GB)`
20. The repeating `Disk 1`, `Disk 2`, and later disk columns

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
