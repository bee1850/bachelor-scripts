#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_ID="Baseline: Installation of TCP Dump should succeed in baseline, but will fail in gVisor. For baseline, raw socket creation should succeed, allowing for local interface sniffing. In gVisor, raw socket creation is hardware-blocked, preventing local interface sniffing."
    ;;
  layer_2)
    INFO_ID="Layer 2: Process lacks CAP_NET_RAW; raw socket creation is hardware-blocked."
    ;;
  layer_3)
    INFO_ID="Layer 3: On containerd with Falco, attempts to create raw sockets or access network interfaces will be blocked and alerted, even if capabilities are present."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac


install_tcp_dump() {
    log_audit_probe "[+] Installing tcpdump for enhanced visibility probe"
    if [ -z "$PROXY" ]; then
        echo "[!] No proxy settings detected. Skipping proxy configuration for tcpdump installation."
        ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- /bin/sh -c 'apk add --no-cache tcpdump > /dev/null 2>&1'"
    else
        echo "[+] Configuring proxy settings for tcpdump installation."
        ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- /bin/sh -c 'export http_proxy=$PROXY; export https_proxy=$PROXY; export no_proxy=localhost,127.0.0.1; apk add --no-cache tcpdump > /dev/null 2>&1; unset http_proxy https_proxy no_proxy'"
    fi
    sleep 10
}

log_audit_probe "[+] Probe - Network Sniffing & Topology Leakage"
log_audit_probe "INFO: $INFO_ID"
case "$LAYER_NAME" in
  baseline|layer_1)
    install_tcp_dump
    ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec  -n $NS_FRONT $NGINX_POD -- /bin/sh -c 'tcpdump -i eth0 -c 10 -A -w /tmp/sniff.pcap > /tmp/tcpdump_init.log 2>&1 &'" 
    sleep 5

    curl -s http://"$TARGET_IP":"$NGINX_PORT" > /dev/null 2>&1
    hey -n 5 -c 1 http://"$TARGET_IP":"$NGINX_PORT"/ > /dev/null 2>&1
    sleep 2

    LISTEN_LOG=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /tmp/tcpdump_init.log")
    SNIFF_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- /bin/sh -c '[ -f /tmp/sniff.pcap ] && tcpdump -A -r /tmp/sniff.pcap || echo \"FILE NOT CREATED: Packet capture failed to initialize.\"'")
    
    ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- rm -f /tmp/sniff.pcap /tmp/tcpdump_init.log" > /dev/null 2>&1
    
    log_audit_probe "Initialization Output: $LISTEN_LOG"
    ;;
  layer_2|layer_3)
    log_audit_probe "Cannot Install tcpdump. Using alternative method by trying to read /proc/net/dev."
    SNIFF_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /proc/net/dev" 2>&1)
    ;;
  *)
    echo "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac
CAP_CHECK=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- grep CapEff /proc/1/status" 2>&1)
log_audit_probe "Effective Capabilities: $CAP_CHECK"
log_audit_probe "Captured Data: $SNIFF_OUT"

# Self-classify
ID_OUTPUTS="$LISTEN_LOG $SNIFF_OUT"
if echo "$ID_OUTPUTS" | grep -qi "tcpdump: listening on eth0"; then
    emit_result "Network Sniffing & Topology Leakage" "Exploited"
elif echo "$SNIFF_OUT" | grep -qi "Inter-\|Receive\|Transmit\|RX\|TX"; then
    # /proc/net/dev is readable — topology leakage, but no raw socket
    emit_result "Network Sniffing & Topology Leakage" "Mitigated"
elif echo "$ID_OUTPUTS" | grep -qi "permission\|operation not permitted\|no such file"; then
    emit_result "Network Sniffing & Topology Leakage" "Prevented"
else
    emit_result "Network Sniffing & Topology Leakage" "Unknown"
fi
log_audit_probe "----------------------------------------------------"