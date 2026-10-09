#!/bin/bash

NAMESPACE="self-healing"
LABEL="app=self-healing-app"

echo "=== Self-Healing Chaos Experiment ==="

echo
echo "[1] Baseline"
kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o wide

POD=$(kubectl get pods \
  -n "$NAMESPACE" \
  -l "$LABEL" \
  -o jsonpath='{.items[0].metadata.name}')

echo
echo "Target Pod: $POD"

START=$(date +%s)

echo
echo "[2] Injecting failure at:"
date

kubectl delete pod "$POD" -n "$NAMESPACE"

echo
echo "[3] Waiting for 3 Ready replicas..."

while true; do
    READY=$(kubectl get pods \
      -n "$NAMESPACE" \
      -l "$LABEL" \
      --no-headers 2>/dev/null |
      awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')

    if [ "$READY" -eq 3 ]; then
        break
    fi

    sleep 1
done

END=$(date +%s)
RECOVERY=$((END - START))

echo
echo "[4] Recovery completed at:"
date

echo
echo "================================="
echo "Self-Healing Result"
echo "================================="
echo "Failed Pod:      $POD"
echo "Ready Replicas:  $READY/3"
echo "Recovery Time:   ${RECOVERY} seconds"
echo "================================="

echo
echo "[5] Final state:"
kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o wide

echo
echo "[6] Service endpoints:"
kubectl get endpointslice -n "$NAMESPACE"