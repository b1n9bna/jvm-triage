# jvm-triage

轻量级 Java 线上应急排障与快照归档工具。单 Shell 脚本、零依赖，3~5 秒内完成 CPU/GC/线程栈采样，输出客观研判报告，避免盲目重启丢失现场或误操作 Dump 导致次生灾害。

[English](./README.md) | 简体中文

## 快速开始

在目标服务器上直接执行：

### 🚀 方式一：国内服务器一键极速执行（推荐）

内置 3 秒超时自动切换加速镜像，彻底解决国内节点访问 `raw.githubusercontent.com` 经常出现的连接超时与 DNS 污染：

```bash
# 自动检测 Java 进程并开始排查（自适应内外网环境）
(curl -fsSL --connect-timeout 3 https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh 2>/dev/null || curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh) | bash

# 或指定 PID
(curl -fsSL --connect-timeout 3 https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh 2>/dev/null || curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh) | bash -s -- <PID>
```

> **直连镜像源**：也可直接使用镜像代理地址：  
> `curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash`

---

### 🌐 方式二：海外节点 / GitHub 原生直连

```bash
# 自动检测 Java 进程并开始排查
curl -fsSL https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash

# 或指定 PID
curl -fsSL https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash -s -- <PID>
```

---

### 📦 方式三：克隆到本地执行

```bash
# 国内加速克隆
git clone https://ghproxy.net/https://github.com/b1n9bna/jvm-triage.git
# 或官方源克隆
# git clone https://github.com/b1n9bna/jvm-triage.git

./jvm-triage/scripts/jvm-triage.sh [PID]
```

## 核心功能

- **多进程选择**：检测到多个 Java 进程时，自动解析 `PID + Jar名/主类名` 生成选择菜单。
- **安全检查**：检查容器 CGroup 配额与磁盘可用空间，防止后续生成 Dump 撑爆磁盘。
- **CPU 线程定位**：采集 CPU Top 5 线程，十进制 TID 自动转十六进制 `nid` 并截取线程栈顶。
- **GC 采样分析**：连续 5 次采样 `jstat -gcutil`，计算 Old 区使用率与 FGC 增量。
- **3 轮 jstack 快照**：间隔 2 秒连抓 3 次线程栈，排查死锁与线程阻塞。
- **根因研判与处置建议**：明确区分是“GC 占满 CPU（需 Dump 内存）”还是“业务代码死循环（无需 Dump，直接查代码行）”。
- **自动归档**：原始日志自动打包为 `/tmp/jvm-triage-<pid>-<time>.tar.gz`，方便离线分析。

## 输出示例

```text
================================================================================
                       JVM-TRIAGE INCIDENT REPORT
================================================================================
[1] System & Runtime Baseline (系统基线与资源限制)
  - Target Process : PID 18422 (Uptime: 04:12)
  - System LoadAvg : 7.82, 6.54, 5.21
  - CGroup Limits  : CPU: 4.0 Cores | Memory: 4096 MB
  - Disk Headroom  : 32.0 GB available on /tmp/jvm-triage-18422-20261111_173000

[2] Telemetry & Vital Signs (核心指标与体征)
  - Overall CPU    : 385.0%
  - Memory Usage   : Eden: 100.0% | Old: 99.8% | Metaspace: 88.5%
  - GC 5s Activity : YGC: 412 | FGC Delta: +3 (FGCT Delta: +2.18s)
  - Thread States  : Total: 280 | RUNNABLE: 120 | BLOCKED: 0 | WAITING: 80

[3] Top CPU Threads & Hotspot Stack Traces (CPU 热点线程与栈顶定位)
  [#1] TID: 18430 | nid: 0x47fe | CPU: 96.2%
    Header: "VM Thread" os_prio=0 tid=0x00007f... nid=0x47fe runnable
  [#2] TID: 18431 | nid: 0x47ff | CPU: 95.1%
    Header: "GC Task Thread#0" os_prio=0 tid=0x00007f... nid=0x47ff runnable

[4] Root Cause Diagnosis & Decision Matrix (根因研判与处置决策)
  >>> Category     : GC_THRASHING_AND_MEMORY_LEAK (老年代耗尽 / 频繁 Full GC)
  >>> Summary      : Severe GC Thrashing detected. High CPU usage is driven by JVM GC threads (Old Gen: 99.8%, FGC Count Delta: +3 in 5s).
                     (Old区已严重耗尽，高 CPU 占用由 JVM GC 线程持续触发 Full GC 引起，属次生表象。)
  >>> Next Actions : Potential memory leak or insufficient heap. High CPU is a SYMPTOM, not the cause. Generating a heap dump is strongly recommended for MAT analysis.
                     (存在内存泄露或堆内存不足。高 CPU 只是表象，根因在堆内存，强烈建议保留 Heap Dump 并使用 MAT 深入分析。)

[5] Safe Operation Guide (安全操作指南)
  [+] Heap dump recommended. Disk headroom is safe (32.0 GB available).
      (建议保留 Heap Dump，磁盘空间安全充足。)
  [+] Recommended Non-Intrusive Dump Command:
      jcmd 18422 GC.heap_dump /tmp/jvm-triage-18422-20261111_173000/heap_dump_18422.hprof
      (Note: Brief STW pause may occur. If in K8s, drain/isolate pod traffic first if possible)
      (注意: 执行 Dump 会导致短暂 STW 停顿；若在 K8s 环境，建议先将 Pod 从 Endpoint 隔离摘流)

[6] Archive & Evidence Preservation (现场快照与归档)
  Raw snapshots saved to: /tmp/jvm-triage-18422-20261111_173000
================================================================================

✓ Scene preserved successfully! (现场快照已打包归档)
Diagnostic bundle created: /tmp/jvm-triage-18422-20261111_173000.tar.gz
```

## 配合 AI Agent 使用

仓库包含 [`skills/jvm-triage/SKILL.md`](./skills/jvm-triage/SKILL.md)。将脚本输出直接发给支持 Skill 的 AI Agent（如 Antigravity / Claude Code / Cursor），AI 会根据堆栈自动定位本地项目中的死循环类和代码行，或给出 Eclipse MAT 离线分析步骤。

## License

[Apache 2.0](LICENSE)
