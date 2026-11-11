#!/usr/bin/env bash
# ==============================================================================
# jvm-triage.sh - JVM Production Incident Triage & Scene Preservation Toolkit
#
# A zero-dependency, lightweight, non-intrusive diagnostic script for Java services.
# Performs 5-sample GC metrics, 3-snapshot thread dumps, top CPU hotspot profiling,
# and generates a definitive diagnostic report with next-step recommendations.
# ==============================================================================

# Note: Do not use set -e to prevent unexpected termination on non-zero exit of optional sub-tools.
set -o pipefail

# ANSI Color Codes
COLOR_RESET="\033[0m"
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_BLUE="\033[1;34m"
COLOR_CYAN="\033[1;36m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"

# Print helpers
info()    { printf "${COLOR_CYAN}[INFO]${COLOR_RESET} %s\n" "$*"; }
warn()    { printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$*"; }
error()   { printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$*" >&2; }
success() { printf "${COLOR_GREEN}[OK]${COLOR_RESET} %s\n" "$*"; }

# ------------------------------------------------------------------------------
# Locate JDK Tools (fallback to JAVA_HOME if not directly in PATH)
# ------------------------------------------------------------------------------
find_jdk_tool() {
    local tool="$1"
    if command -v "$tool" >/dev/null 2>&1; then
        command -v "$tool"
    elif [[ -n "$JAVA_HOME" && -x "$JAVA_HOME/bin/$tool" ]]; then
        echo "$JAVA_HOME/bin/$tool"
    else
        # Try finding standard linux JVM locations
        local candidate
        candidate=$(find /usr/lib/jvm /usr/java /opt/java -name "$tool" -type f -perm -111 2>/dev/null | head -n 1)
        if [[ -n "$candidate" ]]; then
            echo "$candidate"
        else
            echo ""
        fi
    fi
}

CMD_JPS=$(find_jdk_tool "jps")
CMD_JSTAT=$(find_jdk_tool "jstat")
CMD_JSTACK=$(find_jdk_tool "jstack")
CMD_JCMD=$(find_jdk_tool "jcmd")

if [[ -z "$CMD_JSTAT" || -z "$CMD_JSTACK" ]]; then
    warn "JDK tools (jstat/jstack) not found in PATH or standard JAVA_HOME."
    warn "Some runtime telemetry may be limited. Ensure you run this with JDK or as the application user."
    warn "(未在 PATH 或 JAVA_HOME 中找到 jstat/jstack 工具，建议以应用所属用户或在含 JDK 环境下执行)"
fi

# ------------------------------------------------------------------------------
# PID Detection & Interactive Selection
# ------------------------------------------------------------------------------
TARGET_PID=""

select_pid() {
    local requested_pid="$1"
    if [[ -n "$requested_pid" ]]; then
        if kill -0 "$requested_pid" 2>/dev/null; then
            TARGET_PID="$requested_pid"
            return 0
        else
            error "Specified PID $requested_pid is not running or not accessible. (指定 PID $requested_pid 不存在或无权限访问)"
            exit 1
        fi
    fi

    local pids=()
    local descs=()

    if [[ -n "$CMD_JPS" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid=$(echo "$line" | awk '{print $1}')
            local desc=$(echo "$line" | cut -d' ' -f2-)
            # Filter out jps itself
            if [[ "$desc" != *"Jps"* && "$desc" != "sun.tools.jps.Jps" ]]; then
                pids+=("$pid")
                descs+=("$desc")
            fi
        done < <("$CMD_JPS" -l 2>/dev/null)
    else
        # Fallback to ps
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid=$(echo "$line" | awk '{print $1}')
            local desc=$(echo "$line" | cut -d' ' -f2-)
            pids+=("$pid")
            descs+=("${desc:0:80}")
        done < <(ps -eo pid,args | grep -E '[j]ava' | grep -v 'jvm-triage')
    fi

    local count=${#pids[@]}
    if [[ $count -eq 0 ]]; then
        error "No active Java processes detected on this system. (未检测到正在运行的 Java 进程)"
        exit 1
    elif [[ $count -eq 1 ]]; then
        info "Automatically selected the only running Java process: PID ${pids[0]} (${descs[0]}) [已自动选择唯一运行的 Java 进程]"
        TARGET_PID="${pids[0]}"
        return 0
    fi

    # Multiple Java processes found -> Render user selection menu
    printf "\n${COLOR_BOLD}${COLOR_YELLOW}Detected multiple Java processes. Please select the target to inspect (检测到多个 Java 进程，请选择目标序号):${COLOR_RESET}\n"
    printf "%s\n" "--------------------------------------------------------------------------------"
    for i in "${!pids[@]}"; do
        local idx=$((i + 1))
        printf "  ${COLOR_BOLD}[%d]${COLOR_RESET} PID: ${COLOR_CYAN}%-7s${COLOR_RESET} | %s\n" "$idx" "${pids[$i]}" "${descs[$i]}"
    done
    printf "%s\n" "--------------------------------------------------------------------------------"

    while true; do
        local prompt="Enter selection [1-$count] (or 'q' to quit) [输入序号 1-$count，按 q 退出]: "
        local choice=""
        if [[ -r /dev/tty ]]; then
            read -r -p "$prompt" choice < /dev/tty
        else
            read -r -p "$prompt" choice
        fi

        if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            info "Exited by user. (用户取消退出)"
            exit 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            TARGET_PID="${pids[$((choice - 1))]}"
            return 0
        fi
        printf "${COLOR_RED}Invalid input. Please enter a number between 1 and %d. (输入无效，请输入 1 到 %d 之间的数字)${COLOR_RESET}\n" "$count"
    done
}

# ------------------------------------------------------------------------------
# Check Cgroup Resources & Host Metrics
# ------------------------------------------------------------------------------
get_cgroup_info() {
    local pid="$1"
    local cgroup_cpu="Unlimited"
    local cgroup_mem="Unlimited"

    # Cgroup v1 CPU quota
    if [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" && -f "/sys/fs/cgroup/cpu/cpu.cfs_period_us" ]]; then
        local quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)
        local period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)
        if [[ "$quota" -gt 0 && "$period" -gt 0 ]]; then
            local cores=$(awk "BEGIN {printf \"%.1f\", $quota / $period}")
            cgroup_cpu="${cores} Cores (Cgroup v1 limit)"
        fi
    elif [[ -f "/sys/fs/cgroup/cpu.max" ]]; then # Cgroup v2
        local max_line=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo "max 100000")
        local quota=$(echo "$max_line" | awk '{print $1}')
        local period=$(echo "$max_line" | awk '{print $2}')
        if [[ "$quota" != "max" && -n "$period" && "$period" -gt 0 ]]; then
            local cores=$(awk "BEGIN {printf \"%.1f\", $quota / $period}")
            cgroup_cpu="${cores} Cores (Cgroup v2 limit)"
        fi
    fi

    # Cgroup Memory limit
    if [[ -f "/sys/fs/cgroup/memory/memory.limit_in_bytes" ]]; then
        local mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo -1)
        if [[ "$mem_bytes" -gt 0 && "$mem_bytes" -lt 9223372036854771712 ]]; then
            local mem_mb=$((mem_bytes / 1024 / 1024))
            cgroup_mem="${mem_mb} MB (Cgroup v1)"
        fi
    elif [[ -f "/sys/fs/cgroup/memory.max" ]]; then
        local mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "max")
        if [[ "$mem_max" != "max" ]]; then
            local mem_mb=$((mem_max / 1024 / 1024))
            cgroup_mem="${mem_mb} MB (Cgroup v2)"
        fi
    fi

    echo "$cgroup_cpu|$cgroup_mem"
}

# ------------------------------------------------------------------------------
# Disk Space Check
# ------------------------------------------------------------------------------
check_disk_space() {
    local target_dir="$1"
    local avail_mb=0
    if command -v df >/dev/null 2>&1; then
        avail_mb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2 {print int($4 / 1024)}')
    fi
    echo "$avail_mb"
}

# ------------------------------------------------------------------------------
# Main Triage Execution Flow
# ------------------------------------------------------------------------------
select_pid "$1"
if [[ -z "$TARGET_PID" ]]; then
    exit 0
fi
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
WORK_DIR="${2:-/tmp}/jvm-triage-${TARGET_PID}-${TIMESTAMP}"
mkdir -p "$WORK_DIR"

printf "\n${COLOR_BOLD}${COLOR_CYAN}================================================================================${COLOR_RESET}\n"
printf "                ${COLOR_BOLD}JVM-TRIAGE: Incident Diagnosis & Scene Preservation${COLOR_RESET}\n"
printf "                ${COLOR_DIM}[ 生产事故应急排障与快照归档工具 ]${COLOR_RESET}\n"
printf "                Target PID: ${COLOR_GREEN}%s${COLOR_RESET} | Output Dir: ${COLOR_DIM}%s${COLOR_RESET}\n" "$TARGET_PID" "$WORK_DIR"
printf "${COLOR_BOLD}${COLOR_CYAN}================================================================================${COLOR_RESET}\n\n"

info "Step 1/4: Gathering system metrics, uptime, and disk headroom... (采集系统指标、运行时间与磁盘余量)"

# 1. Host and Process uptime
UPTIME_STR="Unknown"
if command -v ps >/dev/null 2>&1; then
    UPTIME_STR=$(ps -p "$TARGET_PID" -o etime= 2>/dev/null | xargs || echo "Unknown")
fi

LOAD_AVG="Unknown"
if [[ -f "/proc/loadavg" ]]; then
    LOAD_AVG=$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')
elif command -v uptime >/dev/null 2>&1; then
    LOAD_AVG=$(uptime | sed -E 's/.*load averages?:[[:space:]]*//' | xargs)
fi

# Cgroups & Disk check
IFS="|" read -r CGROUP_CPU CGROUP_MEM < <(get_cgroup_info "$TARGET_PID")
DISK_FREE_MB=$(check_disk_space "$WORK_DIR")
DISK_FREE_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_FREE_MB / 1024}")

# 2. Top CPU Threads Profile (Linux top -H)
info "Step 2/4: Profiling Top CPU threads... (定位 CPU 占用 Top 线程及十六进制 nid)"
TOP_THREADS_FILE="$WORK_DIR/top_threads.txt"
TOP_PIDS=()
TOP_NIDS=()
TOP_CPUS=()

IS_LINUX=false
if [[ "$(uname -s)" == "Linux" ]]; then
    IS_LINUX=true
fi

if [[ "$IS_LINUX" == "true" ]]; then
    # Collect top threads using top -b -n 1 -H -p $PID
    top -b -n 1 -H -p "$TARGET_PID" > "$WORK_DIR/top_full.txt" 2>/dev/null || true
    # Parse top 5 TID and %CPU (skipping headers)
    if [[ -f "$WORK_DIR/top_full.txt" ]]; then
        awk -v pid="$TARGET_PID" '
            $1 ~ /^[0-9]+$/ {
                print $1, $9
            }
        ' "$WORK_DIR/top_full.txt" | sort -k2 -nr | head -n 5 > "$TOP_THREADS_FILE"
    fi
else
    # macOS fallback (thread-level %cpu is not supported by top without root/dtrace, use ps -M)
    ps -M "$TARGET_PID" 2>/dev/null | head -n 6 > "$TOP_THREADS_FILE" || true
fi

if [[ -f "$TOP_THREADS_FILE" && -s "$TOP_THREADS_FILE" && "$IS_LINUX" == "true" ]]; then
    while read -r tid cpu_pct; do
        [[ -z "$tid" ]] && continue
        local_nid=$(printf "0x%x" "$tid")
        TOP_PIDS+=("$tid")
        TOP_NIDS+=("$local_nid")
        TOP_CPUS+=("$cpu_pct")
    done < "$TOP_THREADS_FILE"
fi

# Overall process CPU
TOTAL_CPU_PCT="0.0"
if command -v ps >/dev/null 2>&1; then
    TOTAL_CPU_PCT=$(ps -p "$TARGET_PID" -o %cpu= 2>/dev/null | xargs || echo "0.0")
fi

# 3. GC Metrics (5 Samples at 1-second intervals)
info "Step 3/4: Sampling JVM Memory & GC statistics (5 samples, 1s interval)... (采样 JVM 内存与 GC 指标: 5次/1秒间隔)"
GC_FILE="$WORK_DIR/jstat_gcutil.txt"
DELTA_FGC=0
DELTA_FGCT="0.0"
LATEST_O="0.0"
LATEST_E="0.0"
LATEST_M="0.0"
LATEST_YGC=0

if [[ -n "$CMD_JSTAT" ]]; then
    "$CMD_JSTAT" -gcutil "$TARGET_PID" 1000 5 > "$GC_FILE" 2>/dev/null || true
    if [[ -f "$GC_FILE" && $(wc -l < "$GC_FILE") -ge 6 ]]; then
        # Line 1 is header: S0 S1 E O M CCS YGC YGCT FGC FGCT GCT
        # Line 2 is Sample 1
        # Line 6 is Sample 5
        FIRST_SAMPLE=$(sed -n '2p' "$GC_FILE")
        LAST_SAMPLE=$(sed -n '6p' "$GC_FILE")

        INIT_FGC=$(echo "$FIRST_SAMPLE" | awk '{print $(NF-2)}')
        INIT_FGCT=$(echo "$FIRST_SAMPLE" | awk '{print $(NF-1)}')

        FINAL_FGC=$(echo "$LAST_SAMPLE" | awk '{print $(NF-2)}')
        FINAL_FGCT=$(echo "$LAST_SAMPLE" | awk '{print $(NF-1)}')

        LATEST_E=$(echo "$LAST_SAMPLE" | awk '{print $3}')
        LATEST_O=$(echo "$LAST_SAMPLE" | awk '{print $4}')
        LATEST_M=$(echo "$LAST_SAMPLE" | awk '{print $5}')
        LATEST_YGC=$(echo "$LAST_SAMPLE" | awk '{print $(NF-4)}')

        if [[ "$FINAL_FGC" =~ ^[0-9]+$ && "$INIT_FGC" =~ ^[0-9]+$ ]]; then
            DELTA_FGC=$((FINAL_FGC - INIT_FGC))
        fi
        if [[ -n "$FINAL_FGCT" && -n "$INIT_FGCT" ]]; then
            DELTA_FGCT=$(awk "BEGIN {printf \"%.2f\", $FINAL_FGCT - $INIT_FGCT}")
        fi
    fi
else
    echo "jstat not available" > "$GC_FILE"
fi

# 4. 3-Snapshot Thread Dumps (2-second intervals)
info "Step 4/4: Capturing 3 consecutive jstack snapshots (2s interval)... (连抓 3 轮 jstack 线程栈快照: 间隔2秒)"
DEADLOCK_FOUND=false
DEADLOCK_DETAILS=""

for round in 1 2 3; do
    DUMP_FILE="$WORK_DIR/jstack_${round}.txt"
    if [[ -n "$CMD_JSTACK" ]]; then
        "$CMD_JSTACK" -l "$TARGET_PID" > "$DUMP_FILE" 2>/dev/null || true
    elif [[ -n "$CMD_JCMD" ]]; then
        "$CMD_JCMD" "$TARGET_PID" Thread.print -l > "$DUMP_FILE" 2>/dev/null || true
    fi

    # Check for deadlocks in this snapshot
    if grep -q "Found one Java-level deadlock:" "$DUMP_FILE" 2>/dev/null; then
        DEADLOCK_FOUND=true
        DEADLOCK_DETAILS=$(awk '/Found one Java-level deadlock:/,/(Found [0-9]+ deadlock|JVM monitor)/' "$DUMP_FILE")
    fi

    if [[ $round -lt 3 ]]; then
        sleep 2
    fi
done

# Thread state statistics from snapshot 1
TOTAL_THREADS=0
RUNNABLE_COUNT=0
BLOCKED_COUNT=0
WAITING_COUNT=0
TIMED_WAITING_COUNT=0

if [[ -f "$WORK_DIR/jstack_1.txt" ]]; then
    RUNNABLE_COUNT=$(grep -c "java.lang.Thread.State: RUNNABLE" "$WORK_DIR/jstack_1.txt" || true)
    BLOCKED_COUNT=$(grep -c "java.lang.Thread.State: BLOCKED" "$WORK_DIR/jstack_1.txt" || true)
    WAITING_COUNT=$(grep -c "java.lang.Thread.State: WAITING" "$WORK_DIR/jstack_1.txt" || true)
    TIMED_WAITING_COUNT=$(grep -c "java.lang.Thread.State: TIMED_WAITING" "$WORK_DIR/jstack_1.txt" || true)
    TOTAL_THREADS=$((RUNNABLE_COUNT + BLOCKED_COUNT + WAITING_COUNT + TIMED_WAITING_COUNT))
fi

# ------------------------------------------------------------------------------
# Match Top CPU NIDs with Thread Dumps & Classify Root Cause
# ------------------------------------------------------------------------------
GC_THREAD_CPU_COUNT=0
BUSINESS_THREAD_CPU_COUNT=0
HOTSPOT_THREAD_REPORTS=()

if [[ ${#TOP_NIDS[@]} -gt 0 && -f "$WORK_DIR/jstack_1.txt" ]]; then
    for idx in "${!TOP_NIDS[@]}"; do
        nid="${TOP_NIDS[$idx]}"
        tid="${TOP_PIDS[$idx]}"
        cpu="${TOP_CPUS[$idx]}"

        # Locate thread in jstack: line matching nid=0x...
        thread_line=$(grep -E "nid=${nid}[ ,]" "$WORK_DIR/jstack_1.txt" | head -n 1 || true)
        
        # Check if matched thread is a GC/VM internal thread
        is_gc=false
        if [[ "$thread_line" =~ "VM Thread" || "$thread_line" =~ "GC Thread" || "$thread_line" =~ "GC Task Thread" || "$thread_line" =~ "G1 Young RemSet" || "$thread_line" =~ "G1 Conc" || "$thread_line" =~ "ParallelGC" || "$thread_line" =~ "ZWorker" ]]; then
            is_gc=true
            ((GC_THREAD_CPU_COUNT++))
        else
            ((BUSINESS_THREAD_CPU_COUNT++))
        fi

        # Extract next 6 lines of stack
        stack_snippet=""
        if [[ -n "$thread_line" ]]; then
            stack_snippet=$(awk -v pattern="nid=${nid}" '
                $0 ~ pattern {
                    found=1; print $0; count=0; next
                }
                found && count < 6 {
                    print "      "$0; count++
                }
                count >= 6 { found=0 }
            ' "$WORK_DIR/jstack_1.txt")
        fi

        HOTSPOT_THREAD_REPORTS+=("[#$((idx + 1))] TID: $tid | nid: ${COLOR_CYAN}$nid${COLOR_RESET} | CPU: ${COLOR_YELLOW}${cpu}%${COLOR_RESET}\n    Header: ${thread_line}\n${stack_snippet}")
    done
fi

# ------------------------------------------------------------------------------
# Root Cause Decision Matrix
# ------------------------------------------------------------------------------
DIAGNOSIS_CATEGORY=""
DIAGNOSIS_SUMMARY=""
ACTION_RECOMMENDATION=""
IS_DUMP_RECOMMENDED=false

# 1. Check Deadlock
if [[ "$DEADLOCK_FOUND" == "true" ]]; then
    DIAGNOSIS_CATEGORY="DEADLOCK_DETECTED (检测到死锁)"
    DIAGNOSIS_SUMMARY="Direct Java-level Deadlock detected between threads competing for monitors/locks.\n                     (检测到明确的 Java 线程死锁，线程互相等待监视器锁/互斥锁。)"
    ACTION_RECOMMENDATION="DO NOT restart blindly. Review the deadlock stack printed below, locate synchronized/Lock acquisitions, and fix lock ordering.\n                     (切勿盲目重启丢失现场！请查看报告中的死锁分析详情，定位双方争抢锁的代码行并调整加锁顺序。)"

# 2. Check Memory Exhaustion / GC Thrashing
elif [[ $GC_THREAD_CPU_COUNT -ge 2 || ($DELTA_FGC -gt 0 && $(echo "$LATEST_O > 85.0" | bc -l 2>/dev/null || echo 0) -eq 1) ]]; then
    DIAGNOSIS_CATEGORY="GC_THRASHING_AND_MEMORY_LEAK (老年代耗尽 / 频繁 Full GC)"
    DIAGNOSIS_SUMMARY="Severe GC Thrashing detected. High CPU usage is driven by JVM GC threads (Old Gen: ${LATEST_O}%, FGC Count Delta: +${DELTA_FGC} in 5s).\n                     (Old区已严重耗尽，高 CPU 占用由 JVM GC 线程持续触发 Full GC 引起，属次生表象。)"
    IS_DUMP_RECOMMENDED=true
    ACTION_RECOMMENDATION="Potential memory leak or insufficient heap. High CPU is a SYMPTOM, not the cause. Generating a heap dump is strongly recommended for MAT analysis.\n                     (存在内存泄露或堆内存不足。高 CPU 只是表象，根因在堆内存，强烈建议保留 Heap Dump 并使用 MAT 深入分析。)"

# 3. Check High CPU Business Thread Spin
elif [[ $(echo "$TOTAL_CPU_PCT > 70.0" | bc -l 2>/dev/null || echo 0) -eq 1 && $BUSINESS_THREAD_CPU_COUNT -ge 1 && $DELTA_FGC -eq 0 ]]; then
    DIAGNOSIS_CATEGORY="CPU_SPIN_IN_APPLICATION_CODE (业务代码死循环 / 高计算消耗)"
    DIAGNOSIS_SUMMARY="CPU spike is caused by application worker threads (e.g., infinite loop, unindexed data scan, heavy regex/crypto). Old Gen and GC metrics are normal.\n                     (CPU 飙高由业务工作线程引起，如无限循环、大集合深度扫描、灾难性正则回溯等；Old 区及 GC 指标正常。)"
    IS_DUMP_RECOMMENDED=false
    ACTION_RECOMMENDATION="DO NOT DUMP HEAP (waste of time/disk). Directly examine the hot code stack trace below to find the exact class and line number.\n                     (切勿 Dump 堆内存！不仅浪费时间、磁盘还会引发 STW。请直接根据下方热点线程 nid 堆栈定位具体业务类和代码行。)"

# 4. Check Thread Starvation / Blocked Pool
elif [[ $BLOCKED_COUNT -gt 20 || ($WAITING_COUNT -gt 200 && $(echo "$TOTAL_CPU_PCT < 30.0" | bc -l 2>/dev/null || echo 0) -eq 1) ]]; then
    DIAGNOSIS_CATEGORY="THREAD_STARVATION_OR_RESOURCE_BOTTLENECK (线程阻塞 / 下游资源瓶颈)"
    DIAGNOSIS_SUMMARY="Low CPU usage but massive BLOCKED/WAITING threads ($BLOCKED_COUNT blocked, $WAITING_COUNT waiting). Likely waiting on slow DB queries, connection pool exhaustion, or external downstream timeouts.\n                     (CPU 占用不高但大量线程处于 BLOCKED/WAITING 状态，通常是数据库连接池耗尽、慢查询或下游 RPC 调用无超时导致堆积。)"
    ACTION_RECOMMENDATION="Check downstream dependencies (MySQL/Redis/Dubbo response times) and connection pool limits. Check threads waiting on locks in jstack.\n                     (排查下游依赖 MySQL/Redis/RPC 的响应时延及连接池配额，并对照下方 jstack 检查正等待锁的堆栈。)"

else
    DIAGNOSIS_CATEGORY="GENERAL_OR_TRANSIENT_ANOMALY (常规波动 / 瞬时突发异常)"
    DIAGNOSIS_SUMMARY="No persistent Full GC loops or deadlocks observed during the 5-sample window. May be transient traffic spike or slow I/O.\n                     (采样窗口内未见持续 Full GC 或死锁，可能为瞬时流量尖峰或下游慢 I/O。)"
    ACTION_RECOMMENDATION="Review the 3 captured jstack files in $WORK_DIR to compare thread progression.\n                     (建议查看归档目录中的 3 份 jstack 快照，比对线程状态演进推进情况。)"
fi

# ------------------------------------------------------------------------------
# Render Diagnostic Report
# ------------------------------------------------------------------------------
REPORT_FILE="$WORK_DIR/diagnostic_report.txt"

{
printf "================================================================================\n"
printf "                       JVM-TRIAGE INCIDENT REPORT\n"
printf "================================================================================\n"
printf "[1] System & Runtime Baseline (系统基线与资源限制)\n"
printf "  - Target Process : PID %s (Uptime: %s)\n" "$TARGET_PID" "$UPTIME_STR"
printf "  - System LoadAvg : %s\n" "$LOAD_AVG"
printf "  - CGroup Limits  : CPU: %s | Memory: %s\n" "$CGROUP_CPU" "$CGROUP_MEM"
printf "  - Disk Headroom  : %s GB available on %s\n" "$DISK_FREE_GB" "$WORK_DIR"
printf "\n"
printf "[2] Telemetry & Vital Signs (核心指标与体征)\n"
printf "  - Overall CPU    : %s%%\n" "$TOTAL_CPU_PCT"
printf "  - Memory Usage   : Eden: %s%% | Old: %s%% | Metaspace: %s%%\n" "$LATEST_E" "$LATEST_O" "$LATEST_M"
printf "  - GC 5s Activity : YGC: %s | FGC Delta: +%d (FGCT Delta: +%ss)\n" "$LATEST_YGC" "$DELTA_FGC" "$DELTA_FGCT"
printf "  - Thread States  : Total: %d | RUNNABLE: %d | BLOCKED: %d | WAITING: %d\n" "$TOTAL_THREADS" "$RUNNABLE_COUNT" "$BLOCKED_COUNT" "$WAITING_COUNT"
printf "\n"
printf "[3] Top CPU Threads & Hotspot Stack Traces (CPU 热点线程与栈顶定位)\n"
if [[ ${#HOTSPOT_THREAD_REPORTS[@]} -eq 0 ]]; then
    printf "  (No individual thread CPU breakdown available on this OS/platform - 当前系统不支持单线程 CPU 细分)\n"
else
    for report in "${HOTSPOT_THREAD_REPORTS[@]}"; do
        printf "  %b\n" "$report"
    done
fi
printf "\n"
if [[ "$DEADLOCK_FOUND" == "true" ]]; then
    printf "[!] CRITICAL: Deadlock Analysis (严重告警: 检测到 Java 死锁)\n"
    printf "%s\n\n" "$DEADLOCK_DETAILS"
fi
printf "[4] Root Cause Diagnosis & Decision Matrix (根因研判与处置决策)\n"
printf "  >>> Category     : %b\n" "$DIAGNOSIS_CATEGORY"
printf "  >>> Summary      : %b\n" "$DIAGNOSIS_SUMMARY"
printf "  >>> Next Actions : %b\n" "$ACTION_RECOMMENDATION"
printf "\n"
printf "[5] Safe Operation Guide (安全操作指南)\n"
if [[ "$IS_DUMP_RECOMMENDED" == "true" ]]; then
    if [[ $DISK_FREE_MB -lt 4096 ]]; then
        printf "  ${COLOR_RED}[DANGER] Available disk is under 4GB (%s GB). DUMPING HEAP MAY CRASH NODE!${COLOR_RESET}\n" "$DISK_FREE_GB"
        printf "  ${COLOR_RED}[!] 磁盘剩余空间不足 4GB，执行 Dump 极可能打满磁盘导致宿主机/节点崩溃！请先清理磁盘空间。${COLOR_RESET}\n"
    else
        printf "  [+] Heap dump recommended. Disk headroom is safe (%s GB available).\n" "$DISK_FREE_GB"
        printf "      (建议保留 Heap Dump，磁盘空间安全充足。)\n"
        printf "  [+] Recommended Non-Intrusive Dump Command:\n"
        printf "      %s %s GC.heap_dump %s/heap_dump_%s.hprof\n" "${CMD_JCMD:-jcmd}" "$TARGET_PID" "$WORK_DIR" "$TARGET_PID"
        printf "      (Note: Brief STW pause may occur. If in K8s, drain/isolate pod traffic first if possible)\n"
        printf "      (注意: 执行 Dump 会导致短暂 STW 停顿；若在 K8s 环境，建议先将 Pod 从 Endpoint 隔离摘流)\n"
    fi
else
    printf "  [-] Heap dump NOT necessary for this scenario. Save disk I/O and avoid unnecessary STW pause.\n"
    printf "      (当前场景【无需 Dump 堆内存】，节省磁盘 I/O 并避免无意义的 STW 业务停顿。)\n"
fi
printf "\n"
printf "[6] Archive & Evidence Preservation (现场快照与归档)\n"
printf "  Raw snapshots saved to: %s\n" "$WORK_DIR"
printf "================================================================================\n"
} | tee "$REPORT_FILE"

# ------------------------------------------------------------------------------
# Package Archive
# ------------------------------------------------------------------------------
TARBALL_PATH="${WORK_DIR}.tar.gz"
tar -czf "$TARBALL_PATH" -C "$(dirname "$WORK_DIR")" "$(basename "$WORK_DIR")" 2>/dev/null || true

printf "\n${COLOR_GREEN}✓ Scene preserved successfully! (现场快照已打包归档)${COLOR_RESET}\n"
printf "Diagnostic bundle created: ${COLOR_BOLD}%s${COLOR_RESET}\n\n" "$TARBALL_PATH"
