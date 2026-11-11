# jvm-triage

轻量级 Java 线上排障与现场保全工具。单 Shell 脚本、零依赖，3~5 秒内完成 CPU/GC/线程栈采样，输出客观研判报告，避免盲目重启丢失现场或误操作 Dump 导致次生灾害。

[English](./README.md) | 简体中文

## 快速开始

在目标服务器上直接执行：

```bash
# 自动检测 Java 进程并开始排查
curl -fsSL https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash

# 或指定 PID
curl -fsSL https://raw.githubusercontent.com/b1n9bna/jvm-triage/main/scripts/jvm-triage.sh | bash -s -- <PID>
```

或克隆到本地执行：

```bash
git clone https://github.com/b1n9bna/jvm-triage.git
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
[1] 基线环境: PID 18422 | LoadAvg: 7.82 | 磁盘剩余: 32 GB (充足)
[2] 核心体征: CPU 385% | Old区: 99.8% | 5秒内发生 3 次 Full GC (耗时 2.18s)
[3] CPU Top 线程:
  - nid: 0x47fe | CPU: 96.2% | "VM Thread"
  - nid: 0x47ff | CPU: 95.1% | "GC Task Thread#0"
[4] 研判结论与处置建议:
  >>> 根因分析: Old 区已满，GC 线程占满 CPU 正在频繁触发 Full GC！
  >>> 下一步动作:
      [+] 磁盘安全，建议生成 Heap Dump 进行 MAT 分析:
          jcmd 18422 GC.heap_dump /tmp/dump_18422.hprof
================================================================================
✓ 现场已打包归档至: /tmp/jvm-triage-18422-20261111_173000.tar.gz
```

## 配合 AI Agent 使用

仓库包含 [`skills/jvm-triage/SKILL.md`](./skills/jvm-triage/SKILL.md)。将脚本输出直接发给支持 Skill 的 AI Agent（如 Antigravity / Claude Code / Cursor），AI 会根据堆栈自动定位本地项目中的死循环类和代码行，或给出 Eclipse MAT 离线分析步骤。

## License

[Apache 2.0](LICENSE)
