#!/bin/bash

log_audit_probe() {
    echo "$@"
    # If AUDIT_FILE is set, append; otherwise skip silently
    if [ -n "$AUDIT_FILE" ]; then
        echo "$@" >> "$AUDIT_FILE"
    fi
}

# emit_result "Probe Name" "Prevented|Mitigated|Exploited|Unknown"
# Writes a machine-parseable line to both the audit log and the results CSV.
emit_result() {
    local probe_name="$1"
    local outcome="$2"
    log_audit_probe "RESULT:${probe_name}:${outcome}"
    if [ -n "$RESULTS_CSV" ]; then
        echo "${LAYER_NAME},${RUNTIME},${probe_name},${outcome}" >> "$RESULTS_CSV"
    fi
}