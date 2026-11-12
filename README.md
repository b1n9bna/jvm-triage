# jvm-triage

A lightweight, zero-dependency JVM incident triage and scene preservation script. Samples CPU, GC metrics, and thread dumps in 3~5 seconds to generate an objective root-cause report, preventing blind restarts and secondary dump disasters.

English | [简体中文](./README_zh.md)

## Quick Start

Run directly on the target host:

```bash
# Auto-detect Java processes and launch triage
curl -fsSL https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash

# Or specify a target PID
curl -fsSL https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash -s -- <PID>
```

> **Tip for users in Mainland China**: If `raw.githubusercontent.com` times out or is unreachable, use the auto-fallback command:
> ```bash
> (curl -fsSL --connect-timeout 3 https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh 2>/dev/null || curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh) | bash
> ```

Or clone locally:

```bash
git clone https://github.com/b1n9bna/jvm-triage.git
./jvm-triage/scripts/jvm-triage.sh [PID]
```

## Features

- **Interactive Selection**: Automatically parses `PID + Jar Name / Main Class` when multiple Java processes exist.
- **Safety Pre-checks**: Inspects container CGroup quotas and free disk headroom to prevent dump-induced node crashes.
- **CPU Hotspots**: Captures Top 5 CPU threads, converts decimal TID to hexadecimal `nid`, and prints stack heads.
- **5-Sample GC Telemetry**: Runs 5 samples of `jstat -gcutil` to calculate Old Gen % and Full GC progression.
- **3-Snapshot Thread Stacks**: Captures 3 consecutive `jstack` dumps (2s interval) to identify deadlocks and true hangs.
- **Root Cause & Actionable Advice**: Distinguishes "GC thrashing (dump recommended)" from "business code spin (no dump needed, inspect code line directly)".
- **Scene Preservation**: Archives raw logs automatically to `/tmp/jvm-triage-<pid>-<time>.tar.gz`.

## Sample Output

```text
================================================================================
                       JVM-TRIAGE INCIDENT REPORT
================================================================================
[1] Baseline : PID 18422 | LoadAvg: 7.82 | Disk Free: 32 GB (Safe)
[2] Vitals   : CPU 385% | Old Gen: 99.8% | 3 Full GCs in past 5s (2.18s spent)
[3] Top Threads:
  - nid: 0x47fe | CPU: 96.2% | "VM Thread"
  - nid: 0x47ff | CPU: 95.1% | "GC Task Thread#0"
[4] Diagnosis & Recommendation:
  >>> Root Cause: Old Gen exhausted. GC threads are thrashing in Full GC loops.
  >>> Action: Disk space is safe. Recommended Heap Dump command:
      jcmd 18422 GC.heap_dump /tmp/dump_18422.hprof
================================================================================
✓ Scene preserved to: /tmp/jvm-triage-18422-20261111_173000.tar.gz
```

## AI Agent Integration

Includes [`skills/jvm-triage/SKILL.md`](./skills/jvm-triage/SKILL.md). Paste the script's terminal output into your AI Agent (Antigravity / Claude Code / Cursor) to automatically correlate stack traces with local files to pinpoint buggy lines or get Eclipse MAT instructions.

## License

[Apache 2.0](LICENSE)
