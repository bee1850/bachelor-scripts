#!/bin/bash
# Usage: ./monitor.sh [-v] <POD_NAME> [NAMESPACE]

VERBOSE=false
while getopts "v" opt; do
  case $opt in
    v) VERBOSE=true ;;
    *) echo "Usage: $0 [-v] <POD_NAME> [NAMESPACE]"; exit 1 ;;
  esac
done
shift $((OPTIND-1))

POD_NAME=$1
NAMESPACE=$2
PHYS_IF="enp0s3" 
OUT_FILE="/tmp/monitor.csv"

if [ -z "$POD_NAME" ]; then
    echo "ERROR: No Pod Name provided."
    exit 1
fi

# 2. PID & CGROUP RESOLUTION
if [ -n "$NAMESPACE" ]; then
    POD_ID=$(sudo crictl pods --label "app=$POD_NAME" --namespace "$NAMESPACE" -q | head -n 1)
    [ -z "$POD_ID" ] && { echo "ERROR: No pod found for app=$POD_NAME in namespace $NAMESPACE"; exit 1; }
    CONT_ID=$(sudo crictl ps --pod "$POD_ID" -q | head -n 1)
else
    CONT_ID=$(sudo crictl ps --name "$POD_NAME" -q | head -n 1)
fi
[ -z "$CONT_ID" ] && { echo "ERROR: No container found"; exit 1; }

PID=$(sudo crictl inspect "$CONT_ID" | jq -r ".info.pid")
IS_GVISOR=$(sudo crictl inspect "$CONT_ID" | jq -r ".info.runtimeType")
SUFFIX=$(cut -d: -f3- < /proc/"$PID"/cgroup)
if [ "$IS_GVISOR" = "io.containerd.runsc.v1" ]; then
    # this is gVisor, we need to find the parent slice
    SCOPE_PATH="/sys/fs/cgroup$SUFFIX"
    [[ "$SCOPE_PATH" == *.scope ]] && POD_PATH=$(dirname "$SCOPE_PATH") || POD_PATH="$SCOPE_PATH"
else
    # this is not gVisor, we can directly use the container's cgroup
    SCOPE_PATH="/sys/fs/cgroup$SUFFIX"
    POD_PATH="$SCOPE_PATH"
fi

# 4. CPU LIMITS
CORES_LIMIT=0
if [ -f "$POD_PATH/cpu.max" ]; then
    read -r L_QUOTA L_PERIOD < "$POD_PATH/cpu.max"
    [ "$L_QUOTA" != "max" ] && CORES_LIMIT=$(awk "BEGIN {print $L_QUOTA / $L_PERIOD}")
fi

MEMORY_LIMIT=0
if [ -f "$POD_PATH/memory.max" ]; then
    read -r MEM_LIMIT < "$POD_PATH/memory.max"
    [ "$MEM_LIMIT" != "max" ] && MEMORY_LIMIT=$(( MEM_LIMIT / 1024 / 1024 ))
fi

# 5. DEBUG INFORMATION (Verbose Only)
if [ "$VERBOSE" = true ]; then
    echo "--- DEBUG INFO ---"
    echo "Pod Name:     $POD_NAME"
    echo "Pod ID:       $POD_ID"
    echo "Cont ID:      $CONT_ID"
    echo "PID:          $PID"
    echo "Runtime:      $IS_GVISOR"
    echo "Scope Path:   $SCOPE_PATH"
    echo "Pod Path:     $POD_PATH"
    echo "CPU Limit:    $CORES_LIMIT cores"
    echo "Memory Limit: $MEMORY_LIMIT MiB"
    echo "Interface:    $PHYS_IF"
    echo "Output:       STDOUT"
    echo "------------------"
fi

# 6. INITIALIZATION
PREV_TS=$(date +%s.%N)
PREV_CPU=$(grep "usage_usec" "$SCOPE_PATH/cpu.stat" | awk '{print $2}')
HEADER="ts,mem_mb,mem_limit,mem_pct_limit,cpu_cores,cpu_cores_limit,cpu_pct_limit,oom,node_kb,net_rx,net_tx"

# 7. OPTIMIZED EXECUTION LOOP
if [ "$VERBOSE" = true ]; then
    echo "$HEADER"
    while true; do
        sleep 1
        CUR_TS=$(date +%s.%N)
        CUR_CPU=$(grep "usage_usec" "$SCOPE_PATH/cpu.stat" | awk '{print $2}')
        
        # --- Updated Working Set Memory Calculation ---
        MEM_TOTAL=$(cat "$SCOPE_PATH/memory.current" 2>/dev/null || echo 0)
        INACTIVE_FILE=$(grep "^inactive_file " "$SCOPE_PATH/memory.stat" 2>/dev/null | awk '{print $2}' || echo 0)
        MEM_WS=$(( MEM_TOTAL - INACTIVE_FILE ))
        # Prevent negative values just in case of race conditions
        [ "$MEM_WS" -lt 0 ] && MEM_WS=0 
        MEM_MB=$(( MEM_WS / 1024 / 1024 ))
        # ----------------------------------------------

        OOM=$(grep "oom_kill" "$POD_PATH/memory.events" 2>/dev/null | awk '{print $2}' || echo 0)
        NODE_MEM=$(grep "Active:" /proc/meminfo | awk '{print $2}')
        read -r _ RX _ _ _ _ _ _ _ TX _ < <(grep "$PHYS_IF" /proc/net/dev)

        awk -v cts="$CUR_TS" -v pts="$PREV_TS" \
            -v ccpu="$CUR_CPU" -v pcpu="$PREV_CPU" \
            -v lim="$CORES_LIMIT" -v lim_mem="$MEMORY_LIMIT" \
            -v mem="$MEM_MB" -v oom="$OOM" -v nmem="$NODE_MEM" \
            -v rx="$RX" -v tx="$TX" 'BEGIN {
            
            dur = cts - pts;
            if (dur <= 0) dur = 1; # Prevent division by zero or negative time

            delta = ccpu - pcpu;
            # Convert nanoseconds to seconds (assuming CPU is in ns)
            cores = delta / (dur * 1000000000); 
            
            pct = (lim > 0) ? (cores / lim) * 100 : 0;
            mem_pct = (lim_mem > 0) ? (mem / lim_mem) * 100 : 0;

            printf "%d MiB / %d MiB (%.2f%%), %.4f / %.2f Cores (%.2f%%), %d MiB Node Total, %s KB DOWN, %s KB UP\n", 
                mem, lim_mem, mem_pct, cores, lim, pct, nmem, rx, tx
        }'
        PREV_TS=$CUR_TS; PREV_CPU=$CUR_CPU
    done
else
    echo "$HEADER" > "$OUT_FILE"
    while true; do
        sleep 1
        CUR_TS=$(date +%s.%N)
        CUR_CPU=$(grep "usage_usec" "$SCOPE_PATH/cpu.stat" | awk '{print $2}')
        
        # --- Updated Working Set Memory Calculation ---
        MEM_TOTAL=$(cat "$SCOPE_PATH/memory.current" 2>/dev/null || echo 0)
        if [ -z "$MEM_TOTAL" ]; then
            echo "ERROR: Cgroup path lost. Container may have restarted." >> /tmp/monitor_boot.log
            exit 1
        fi
        INACTIVE_FILE=$(grep "^inactive_file " "$SCOPE_PATH/memory.stat" 2>/dev/null | awk '{print $2}' || echo 0)
        MEM_WS=$(( MEM_TOTAL - INACTIVE_FILE ))
        [ "$MEM_WS" -lt 0 ] && MEM_WS=0
        MEM_MB=$(( MEM_WS / 1024 / 1024 ))
        # ----------------------------------------------

        OOM=$(grep "oom_kill" "$POD_PATH/memory.events" 2>/dev/null | awk '{print $2}' || echo 0)
        NODE_MEM=$(grep "Active:" /proc/meminfo | awk '{print $2}')
        read -r _ RX _ _ _ _ _ _ _ TX _ < <(grep "$PHYS_IF" /proc/net/dev)

        awk -v cts="$CUR_TS" -v pts="$PREV_TS" -v ccpu="$CUR_CPU" -v pcpu="$PREV_CPU" \
            -v lim="$CORES_LIMIT" -v lim_mem="$MEMORY_LIMIT" -v mem="$MEM_MB" -v oom="$OOM" -v nmem="$NODE_MEM" \
            -v rx="$RX" -v tx="$TX" 'BEGIN {
                dur = cts - pts;
                mem_pct = (lim_mem > 0) ? (mem / lim_mem) * 100 : 0;
                delta = ccpu - pcpu;
                cores = delta / (dur * 1000000);
                pct = (lim > 0) ? (cores / lim) * 100 : 0;
                printf "%.6f,%d,%d,%.4f,%.4f,%.4f,%.2f,%d,%d,%s,%s\n", cts, mem, lim_mem, mem_pct, cores, lim, pct, oom, nmem, rx, tx
            }' >> "$OUT_FILE"
        PREV_TS=$CUR_TS; PREV_CPU=$CUR_CPU
    done
fi