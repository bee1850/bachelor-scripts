#!/bin/bash

run_workload() {
  local NAME=$1
  local CMD=$2
  local NAMESPACE=${3:-"default"}
  local OUT_DIR="$RESULTS_DIR/$NAME"
  mkdir -p "$OUT_DIR"

  echo "[*] Starting Benchmark: $NAME"
  ssh -q "$TARGET_USER"@"$TARGET_IP" "sudo rm -f /tmp/monitor.csv"
  ssh -q "$TARGET_USER"@"$TARGET_IP" "sudo setsid /root/monitor.sh $NAME $NAMESPACE > /tmp/monitor_boot.log 2>&1 &"
  
  sleep 5
  echo "[*] Executing Workload Command..."
  eval "$CMD" | tee "$OUT_DIR/bench_output.txt"
  
  echo "[*] Stopping monitor and fetching telemetry..."
  ssh -q "$TARGET_USER"@"$TARGET_IP" "sudo pkill -f monitor.sh"
  sleep 2
  scp -q "$TARGET_USER"@"$TARGET_IP":/tmp/monitor.csv "$OUT_DIR/${NAME}_${LAYER_NAME}_${RUNTIME}.csv"
}
echo "[*] Waiting for Postgres to be Ready..."
MAX_RETRIES=300
RETRY_COUNT=0
echo "Target IP: $TARGET_IP, Postgres Port: $POSTGRES_PORT"
until pg_isready -h "$TARGET_IP" -p "$POSTGRES_PORT" -U postgres -q; do
  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "[-] Timeout waiting for Postgres to be ready."
    exit 1
  fi
  sleep 1
  RETRY_COUNT=$((RETRY_COUNT+1))
done

echo "[*] Initializing Postgres DB..."
PGPASSWORD=edge-thesis-pass psql -h "$TARGET_IP" -p "$POSTGRES_PORT" -U postgres -c "CREATE DATABASE pgbenchdb" 2>/dev/null || true
PGPASSWORD=edge-thesis-pass pgbench -i -s 100 -h "$TARGET_IP" -p "$POSTGRES_PORT" -U postgres pgbenchdb 2>&1
ssh -q "$TARGET_USER"@"$TARGET_IP" "sync"
sleep 30

echo "=========================================="
echo " 1. PERFORMANCE BENCHMARKS"
echo "=========================================="

run_workload "postgres" "PGPASSWORD=edge-thesis-pass pgbench -n -c 100 -j 4 -T $DURATION -h $TARGET_IP -p $POSTGRES_PORT -U postgres pgbenchdb" "$NS_BACK"
sleep 10
run_workload "nginx" "hey -c 100 -z ${DURATION}s http://$TARGET_IP:$NGINX_PORT/" "$NS_FRONT"