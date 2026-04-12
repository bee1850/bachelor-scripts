#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_CR="Baseline and Layer 1: ServiceAccountTokens are explicitly enabled by default in Kubernetes, so the token should be visible and accessible inside the container."
    ;;
  layer_2|layer_3)
    INFO_CR="Layers 2-3: ServiceAccountTokens should be invisible and inaccessible inside the container due to projected service account tokens or other mitigations."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac


log_audit_probe "[+] Probe - Service Account Token API Abuse"
# Check if the token mount even exists
log_audit_probe "$INFO_CR"
RECON_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/token" 2>&1)
log_audit_probe "Service Account Token: $RECON_OUT"

SA_OUTCOME="Unknown"
if echo "$RECON_OUT" | grep -qi "No such file or directory\|Permission denied"; then
    SA_OUTCOME="Prevented"
    log_audit_probe "Token not mounted or inaccessible."
else
    # Token exists, try API call
    API_RETURN=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- sh -c '
        TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token);
        curl -s -k -H \"Authorization: Bearer \$TOKEN\" \
        https://kubernetes.default.svc/api/v1/namespaces/default/pods' | jq '.kind'")
    log_audit_probe ""
    log_audit_probe "API Response Kind: $API_RETURN"
    if echo "$API_RETURN" | grep -qi "PodList\|Status"; then
        SA_OUTCOME="Exploited"
    elif echo "$API_RETURN" | grep -qi "Forbidden\|Unauthorized"; then
        SA_OUTCOME="Mitigated"
    else
        SA_OUTCOME="Exploited"
    fi
fi
emit_result "Service Account Token API Abuse" "$SA_OUTCOME"
log_audit_probe "----------------------------------------------------"