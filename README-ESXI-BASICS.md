# ESXi Performance Data in Simple Terms

## What Is ESXi?

ESXi is software installed on a physical server.

It allows one physical server to run several virtual machines, or VMs.

```text
Physical server running ESXi
|
+-- Windows VM
+-- Linux VM
+-- Database VM
+-- Test VM
```

ESXi shares the physical server's CPU, memory, disks, and network connections between those VMs.

## What Is a Performance Sample?

A performance sample is one measurement showing how busy a VM was.

For example:

```text
12:00:00  CPU usage was 10%
12:00:20  CPU usage was 25%
12:00:40  CPU usage was 15%
```

ESXi normally records a real-time measurement every 20 seconds.

Think of it as ESXi taking a photograph of the VM's activity every 20 seconds.

## Why Every 20 Seconds?

VMware uses 20 seconds as a practical balance:

- It is frequent enough to show short periods of high activity.
- It does not create too much monitoring data.
- It leaves the server free to focus on running the VMs.

Measuring every millisecond would create a huge amount of data and use resources that the VMs need.

## How Many Samples Are in One Hour?

One minute contains 60 seconds.

If ESXi records one sample every 20 seconds, it records three samples per minute:

```text
60 seconds / 20 seconds = 3 samples per minute
```

Over 60 minutes:

```text
3 samples per minute x 60 minutes = 180 samples
```

The same calculation can be written as:

```text
60 minutes x 60 seconds = 3,600 seconds
3,600 seconds / 20 seconds = 180 samples
```

## Why Is Real-Time Data Limited to About 60 Minutes?

Think of ESXi as having a small reusable notepad for detailed performance data.

When the notepad is full, each new sample replaces the oldest sample.

```text
New sample arrives
       |
       v
Oldest sample is replaced
```

ESXi's main job is to run virtual machines, not to be a long-term reporting database. Keeping a short detailed history reduces the amount of memory and storage used for monitoring.

## Why Can We Not Request More Samples?

The script can ask for more samples, but it cannot retrieve measurements that ESXi no longer has.

For example:

```text
The script requests: 1,000 samples
ESXi has available:    180 samples
ESXi returns:          180 samples
```

`MaxSamples` means:

```text
Return no more than this number of existing samples.
```

It does not tell ESXi to create missing samples or recover overwritten samples.

If a VM was only recently powered on, ESXi may have fewer than 180 samples for it.

## What Does vCenter Do?

vCenter manages ESXi hosts and keeps historical performance information.

```text
ESXi records recent detailed measurements
                    |
                    v
vCenter collects and stores summaries
                    |
                    v
Reports can cover days, weeks, or months
```

Older data is usually less detailed so that it requires less storage.

For example:

| Period | Typical measurement detail |
|---|---|
| Real-time | Every 20 seconds |
| Past day | Every 5 minutes |
| Past week | Every 30 minutes |
| Past month | Every 2 hours |
| Past year | Every day |

The exact retention periods depend on the vCenter configuration.

## Simple Summary

```text
ESXi:
- Runs the virtual machines.
- Records detailed recent measurements.
- Normally records one real-time sample every 20 seconds.
- Does not act as a long-term performance database.

vCenter:
- Manages ESXi hosts.
- Collects and summarizes performance data.
- Keeps history covering longer periods.
```

Use standalone ESXi when you need a recent snapshot.

Use vCenter when you need reports covering days, weeks, or months.

## Official Documentation

- [VMware vSphere PerformanceManager](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.PerformanceManager.html)
- [VMware PowerCLI Get-Stat](https://developer.broadcom.com/powercli/latest/vmware.vimautomation.core/commands/get-stat)
