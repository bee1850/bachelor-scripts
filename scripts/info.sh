#!/bin/bash

if [ "$LAYER_NAME" != "baseline" ] && [ "$LAYER_NAME" != "layer_1" ]; then
    kubectl get tenants
    echo ""
    echo ""
fi
kubectl get pods -A
echo ""
echo ""
kubectl get svc -A