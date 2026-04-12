#!/bin/bash

log_audit_probe() {
    echo "$@"
    if [ -n "$AUDIT_FILE" ]; then
        echo "$@" >> "$AUDIT_FILE"
    fi
}

emit_result() {
    local probe_name="$1"
    local outcome="$2"
    log_audit_probe "RESULT:${probe_name}:${outcome}"
    if [ -n "$RESULTS_CSV" ]; then
        echo "${LAYER_NAME},${RUNTIME},${probe_name},${outcome}" >> "$RESULTS_CSV"
    fi
}