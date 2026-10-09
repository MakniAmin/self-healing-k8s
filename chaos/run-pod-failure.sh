#!/bin/bash

set -e

NAMESPACE="self-healing"
LABEL="app=self-healing-app"
EXPECTED_REPLICAS=3

RESULTS_DIR="chaos/results"
RESULTS_FILE="$RESULTS_DIR/pod-failure-results.csv"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$RESULTS_FILE" ]; then
    echo "timestamp,experiment,initial_replicas,final_replicas,recovery_seconds,result" \
        > "$RESULTS_FILE"
fi

echo "========================================"
echo " Self-Healing Chaos Experiment"
echo "========================================"

echo
echo "[1] Checking baseline..."

READY=$(kubectl get pods \
  -n "$NAMESPACE" \
  -l "$LABEL" \
  --no-headers |
  awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')

if [ "$READY" -ne "$EXPECTED_REPLICAS" ]; then
    echo "ERROR: Application is not healthy."
    echo "Expected: $EXPECTED_REPLICAS Ready replicas"
    echo "Found:    $READY"
    exit 1
fi

echo "Baseline: $READY/$EXPECTED_REPLICAS replicas Ready"

echo
echo "[2] Injecting Pod failure..."

START=$(date +%s)

kubectl apply -f chaos/pod-failure.yaml

echo "Failure injected at:"
date

echo
echo "[3] Waiting for recovery..."

while true; do

    READY=$(kubectl get pods \
      -n "$NAMESPACE" \
      -l "$LABEL" \
      --no-headers 2>/dev/null |
      awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')

    if [ "$READY" -eq "$EXPECTED_REPLICAS" ]; then
        break
    fi

    sleep 1
done

END=$(date +%s)

RECOVERY=$((END - START))

if [ "$READY" -eq "$EXPECTED_REPLICAS" ]; then
    RESULT="PASS"
else
    RESULT="FAIL"
fi

echo "$(date -Iseconds),pod-kill,$EXPECTED_REPLICAS,$READY,$RECOVERY,$RESULT" \
    >> "$RESULTS_FILE"

echo
echo "Recovery completed at:"
date

echo
echo "========================================"
echo " Experiment Result"
echo "========================================"
echo "Initial replicas: $EXPECTED_REPLICAS"
echo "Final replicas:   $READY"
echo "Recovery time:    ${RECOVERY} seconds"
echo "========================================"

echo
echo "[4] Final application state:"

kubectl get pods \
  -n "$NAMESPACE" \
  -l "$LABEL" \
  -o wide

echo
echo "[5] Cleaning up Chaos Mesh experiment..."

kubectl delete podchaos app-pod-failure \
  -n "$NAMESPACE" \
  --ignore-not-found

echo
echo "Experiment completed."