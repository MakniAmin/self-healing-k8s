#!/bin/bash

set -u

NAMESPACE="self-healing"
LABEL="app=self-healing-app"
EXPECTED_REPLICAS=3

RECOVERY_TIMEOUT=120

RESULTS_DIR="chaos/results"
RESULTS_FILE="$RESULTS_DIR/app-health-failure-results.csv"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$RESULTS_FILE" ]; then
    echo "timestamp,experiment,pod,initial_restarts,final_restarts,recovery_seconds,result" \
        > "$RESULTS_FILE"
fi

POD=""

cleanup() {
    if [ -n "$POD" ]; then
        echo
        echo "[CLEANUP] Restoring /health on $POD..."

        kubectl exec -n "$NAMESPACE" "$POD" -- \
            sh -c 'if [ -f /usr/share/nginx/html/health.bak ]; then mv /usr/share/nginx/html/health.bak /usr/share/nginx/html/health; fi' \
            >/dev/null 2>&1 || true

        echo "[CLEANUP] Done."
    fi
}

trap cleanup EXIT

echo "=========================================="
echo " Application Health Failure Experiment"
echo "=========================================="

echo
echo "[1] Checking application..."

kubectl get deployment self-healing-app -n "$NAMESPACE"

echo
kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o wide

READY=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    --no-headers 2>/dev/null |
    awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')

if [ "$READY" -ne "$EXPECTED_REPLICAS" ]; then
    echo
    echo "ERROR: Application is not healthy."
    echo "Expected: $EXPECTED_REPLICAS Ready replicas"
    echo "Found: $READY"
    exit 1
fi

echo
echo "Initial replicas: $READY/$EXPECTED_REPLICAS"

echo
echo "[2] Selecting a Pod..."

POD=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o jsonpath='{.items[0].metadata.name}')

echo "Selected Pod: $POD"

echo
echo "[3] Checking /health..."

HEALTH=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
    cat /usr/share/nginx/html/health 2>/dev/null || echo "")

if [ "${HEALTH^^}" != "OK" ]; then
    echo
    echo "ERROR: /health is not currently healthy."
    echo "Expected: OK"
    echo "Found: $HEALTH"
    exit 1
fi

echo "/health is healthy."

INITIAL_RESTARTS=$(kubectl get pod "$POD" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}')

echo "Initial restart count: $INITIAL_RESTARTS"

echo
echo "[4] Injecting application health failure..."

START=$(date +%s)

kubectl exec -n "$NAMESPACE" "$POD" -- \
    mv /usr/share/nginx/html/health \
       /usr/share/nginx/html/health.bak

echo "Health endpoint disabled."

echo
echo "[5] Waiting for container restart..."

while true; do

    CURRENT_RESTARTS=$(kubectl get pod "$POD" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' \
        2>/dev/null || echo "$INITIAL_RESTARTS")

    READY_STATUS=$(kubectl get pod "$POD" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].ready}' \
        2>/dev/null || echo "false")

    if [ "$CURRENT_RESTARTS" -gt "$INITIAL_RESTARTS" ]; then
        echo
        echo "Container restart detected."
        break
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    if [ "$ELAPSED" -ge "$RECOVERY_TIMEOUT" ]; then
        echo
        echo "ERROR: Container did not restart within ${RECOVERY_TIMEOUT}s."
        exit 1
    fi

    echo "Waiting for restart... (${ELAPSED}s)"
    sleep 2
done

echo
echo "[6] Waiting for Pod to become Ready again..."

while true; do

    READY_STATUS=$(kubectl get pod "$POD" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].ready}' \
        2>/dev/null || echo "false")

    PHASE=$(kubectl get pod "$POD" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' \
        2>/dev/null || echo "Unknown")

    if [ "$PHASE" = "Running" ] && [ "$READY_STATUS" = "true" ]; then
        break
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    if [ "$ELAPSED" -ge "$RECOVERY_TIMEOUT" ]; then
        echo
        echo "ERROR: Pod did not become Ready within ${RECOVERY_TIMEOUT}s."
        exit 1
    fi

    echo "Waiting for Pod readiness... (${ELAPSED}s)"
    sleep 2
done

END=$(date +%s)
RECOVERY=$((END - START))

FINAL_RESTARTS=$(kubectl get pod "$POD" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}')

echo
echo "=========================================="
echo " Experiment Result"
echo "=========================================="
echo "Pod:                  $POD"
echo "Initial restarts:     $INITIAL_RESTARTS"
echo "Final restarts:       $FINAL_RESTARTS"
echo "Recovery time:        ${RECOVERY}s"
echo "Result:               PASS"
echo "=========================================="

TIMESTAMP=$(date -Iseconds)

echo "$TIMESTAMP,app-health-failure,$POD,$INITIAL_RESTARTS,$FINAL_RESTARTS,$RECOVERY,PASS" \
    >> "$RESULTS_FILE"

echo
echo "Result saved to:"
echo "$RESULTS_FILE"

echo
echo "[7] Current application state..."

kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o wide