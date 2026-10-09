#!/bin/bash

set -u

NAMESPACE="self-healing"
LABEL="app=self-healing-app"

FAILED_NODE=""
EXPECTED_REPLICAS=3

NODE_DETECTION_TIMEOUT=180
POD_CREATION_TIMEOUT=600
POD_READY_TIMEOUT=600
NODE_RESTORE_TIMEOUT=180

RESULTS_DIR="chaos/results"
RESULTS_FILE="$RESULTS_DIR/node-failure-results-v4.csv"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$RESULTS_FILE" ]; then
    echo "timestamp,experiment,failed_node,original_pod,replacement_pod,initial_replicas,final_replicas,detection_seconds,pod_creation_seconds,pod_ready_seconds,ready_after_creation_seconds,node_restore_seconds,result" \
        > "$RESULTS_FILE"
fi


# ============================================================
# Cleanup
# ============================================================

cleanup() {

    echo
    echo "[CLEANUP] Ensuring $FAILED_NODE is running..."

    docker start "$FAILED_NODE" >/dev/null 2>&1 || true

    echo "[CLEANUP] Waiting for $FAILED_NODE to become Ready..."

    local START_TIME
    START_TIME=$(date +%s)

    while true; do

        local NODE_READY

        NODE_READY=$(kubectl get node "$FAILED_NODE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || echo "Unknown")

        if [ "$NODE_READY" = "True" ]; then
            echo "[CLEANUP] $FAILED_NODE is Ready."
            break
        fi

        local NOW
        NOW=$(date +%s)

        if [ $((NOW - START_TIME)) -ge "$NODE_RESTORE_TIMEOUT" ]; then
            echo "[CLEANUP] WARNING: node did not become Ready within timeout."
            break
        fi

        sleep 2
    done
}

trap cleanup EXIT


# ============================================================
# HEADER
# ============================================================

echo "=========================================="
echo " Node Failure + Pod Replacement Experiment"
echo "=========================================="


# ============================================================
# 1. Cluster
# ============================================================

echo
echo "[1] Checking cluster..."

kubectl get nodes


# ============================================================
# 2. Application baseline
# ============================================================

echo
echo "[2] Checking application..."

kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o wide


INITIAL_READY=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    --no-headers 2>/dev/null |
    awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')


if [ "$INITIAL_READY" -ne "$EXPECTED_REPLICAS" ]; then
    echo
    echo "ERROR: Application is not healthy."
    echo "Expected: $EXPECTED_REPLICAS"
    echo "Found:    $INITIAL_READY"
    exit 1
fi


echo
echo "Initial replicas: $INITIAL_READY/$EXPECTED_REPLICAS"


# ============================================================
# 3. Find original Pod
# ============================================================

echo
echo "[3] Finding a worker node containing an application Pod..."

ORIGINAL_POD=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' |
    while read -r POD NODE; do

        if [ "$NODE" = "devops-lab-worker" ] || \
           [ "$NODE" = "devops-lab-worker2" ]; then

            echo "$POD $NODE"
            break

        fi

    done |
    awk '{print $1}')

if [ -z "$ORIGINAL_POD" ]; then
    echo "ERROR: No application Pod found on a worker node."
    exit 1
fi

FAILED_NODE=$(kubectl get pod "$ORIGINAL_POD" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.nodeName}')

echo
echo "Selected failed node: $FAILED_NODE"
echo "Original Pod:        $ORIGINAL_POD"


# ============================================================
# 4. Save baseline Pod names
# ============================================================

echo
echo "[4] Saving baseline Pod list..."

BASELINE_PODS=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')


echo
echo "Baseline Pods:"
echo "$BASELINE_PODS"


# ============================================================
# 5. Failure injection
# ============================================================

echo
echo "[5] Injecting node failure..."

START=$(date +%s)

date

echo
echo "Stopping Docker container:"
echo "$FAILED_NODE"

docker stop "$FAILED_NODE"


# ============================================================
# 6. Node failure detection
# ============================================================

echo
echo "[6] Waiting for Kubernetes to detect node failure..."

DETECTION_START=$(date +%s)

while true; do

    NODE_READY=$(kubectl get node "$FAILED_NODE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || echo "Unknown")

    if [ "$NODE_READY" != "True" ]; then
        break
    fi

    NOW=$(date +%s)

    if [ $((NOW - DETECTION_START)) -ge "$NODE_DETECTION_TIMEOUT" ]; then
        echo
        echo "ERROR: Node failure was not detected within timeout."
        exit 1
    fi

    sleep 1
done


DETECTION_END=$(date +%s)

DETECTION_TIME=$((DETECTION_END - START))


echo
echo "Node failure detected."
echo "Detection time: ${DETECTION_TIME}s"


# ============================================================
# 7. Wait for NEW Pod creation
# ============================================================

echo
echo "[7] Waiting for NEW replacement Pod to be CREATED..."

REPLACEMENT_POD=""

POD_CREATION_START=$(date +%s)

while true; do

    POD_LIST=$(kubectl get pods \
        -n "$NAMESPACE" \
        -l "$LABEL" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || echo "")


    for POD in $POD_LIST; do

        # Ignore baseline Pods
        if echo "$BASELINE_PODS" | grep -Fxq "$POD"; then
            continue
        fi


        # We found a genuinely new Pod
        REPLACEMENT_POD="$POD"
        break

    done


    if [ -n "$REPLACEMENT_POD" ]; then
        break
    fi


    NOW=$(date +%s)

    ELAPSED=$((NOW - POD_CREATION_START))


    if [ "$ELAPSED" -ge "$POD_CREATION_TIMEOUT" ]; then

        echo
        echo "ERROR: No new replacement Pod was created within ${POD_CREATION_TIMEOUT}s."

        kubectl get pods \
            -n "$NAMESPACE" \
            -l "$LABEL" \
            -o wide

        exit 1
    fi


    echo "Waiting for new Pod creation... (${ELAPSED}s)"

    sleep 2

done


POD_CREATION_END=$(date +%s)

POD_CREATION_TIME=$((POD_CREATION_END - START))


echo
echo "NEW replacement Pod created:"
echo "$REPLACEMENT_POD"

echo
echo "Replacement Pod details:"

kubectl get pod "$REPLACEMENT_POD" \
    -n "$NAMESPACE" \
    -o wide


echo
echo "Pod creation time: ${POD_CREATION_TIME}s"


# ============================================================
# 8. Wait for replacement Pod to become Ready
# ============================================================

echo
echo "[8] Waiting for replacement Pod to become Ready..."

POD_READY_START=$(date +%s)

while true; do

    PHASE=$(kubectl get pod "$REPLACEMENT_POD" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' \
        2>/dev/null || echo "Unknown")


    READY=$(kubectl get pod "$REPLACEMENT_POD" \
        -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].ready}' \
        2>/dev/null || echo "false")


    if [ "$PHASE" = "Running" ] && [ "$READY" = "true" ]; then
        break
    fi


    NOW=$(date +%s)

    ELAPSED=$((NOW - POD_READY_START))


    if [ "$ELAPSED" -ge "$POD_READY_TIMEOUT" ]; then

        echo
        echo "ERROR: Replacement Pod did not become Ready within ${POD_READY_TIMEOUT}s."

        kubectl get pod "$REPLACEMENT_POD" \
            -n "$NAMESPACE" \
            -o wide

        exit 1
    fi


    echo "Waiting for Pod readiness... (${ELAPSED}s)"

    sleep 2

done


POD_READY_END=$(date +%s)

TOTAL_RECOVERY_TIME=$((POD_READY_END - START))

READY_AFTER_CREATION=$((POD_READY_END - POD_CREATION_END))


echo
echo "Replacement Pod is Ready."

echo
echo "Replacement Pod details:"

kubectl get pod "$REPLACEMENT_POD" \
    -n "$NAMESPACE" \
    -o wide


echo
echo "Ready after creation: ${READY_AFTER_CREATION}s"

echo "Total recovery time:  ${TOTAL_RECOVERY_TIME}s"


# ============================================================
# 9. Verify application
# ============================================================

echo
echo "[9] Checking application state..."

kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o wide


FINAL_READY=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    --no-headers 2>/dev/null |
    awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')


echo
echo "Final Ready replicas: $FINAL_READY/$EXPECTED_REPLICAS"


# ============================================================
# 10. Verify Deployment
# ============================================================

echo
echo "[10] Checking Deployment..."

DEPLOYMENT_READY=$(kubectl get deployment self-healing-app \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' \
    2>/dev/null || echo "0")


DEPLOYMENT_AVAILABLE=$(kubectl get deployment self-healing-app \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' \
    2>/dev/null || echo "0")


echo
echo "Deployment Ready:     ${DEPLOYMENT_READY:-0}/$EXPECTED_REPLICAS"

echo "Deployment Available: ${DEPLOYMENT_AVAILABLE:-0}/$EXPECTED_REPLICAS"


# ============================================================
# 11. Restore node
# ============================================================

echo
echo "[11] Restoring failed node..."

RESTORE_START=$(date +%s)

docker start "$FAILED_NODE" >/dev/null 2>&1 || true


echo
echo "Waiting for $FAILED_NODE to become Ready..."


while true; do

    NODE_READY=$(kubectl get node "$FAILED_NODE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || echo "Unknown")


    if [ "$NODE_READY" = "True" ]; then
        break
    fi


    NOW=$(date +%s)

    RESTORE_ELAPSED=$((NOW - RESTORE_START))


    if [ "$RESTORE_ELAPSED" -ge "$NODE_RESTORE_TIMEOUT" ]; then
        echo
        echo "WARNING: Node did not become Ready within timeout."
        break
    fi


    sleep 2

done


RESTORE_END=$(date +%s)

RESTORE_TIME=$((RESTORE_END - RESTORE_START))


echo
echo "Node restoration time: ${RESTORE_TIME}s"


# ============================================================
# 12. Final verification
# ============================================================

echo
echo "[12] Final verification..."

echo
echo "Nodes:"

kubectl get nodes


echo
echo "Application Pods:"

kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    -o wide


FINAL_READY=$(kubectl get pods \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    --no-headers 2>/dev/null |
    awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')


echo
echo "Final Ready replicas: $FINAL_READY/$EXPECTED_REPLICAS"


# ============================================================
# 13. Result
# ============================================================

RESULT="FAIL"


if [ "$FINAL_READY" -eq "$EXPECTED_REPLICAS" ] &&
   [ "${DEPLOYMENT_READY:-0}" -eq "$EXPECTED_REPLICAS" ] &&
   [ "${DEPLOYMENT_AVAILABLE:-0}" -eq "$EXPECTED_REPLICAS" ]; then

    RESULT="PASS"

fi


# ============================================================
# 14. Save results
# ============================================================

TIMESTAMP=$(date -Iseconds)


echo "$TIMESTAMP,node-failure,$FAILED_NODE,$ORIGINAL_POD,$REPLACEMENT_POD,$EXPECTED_REPLICAS,$FINAL_READY,$DETECTION_TIME,$POD_CREATION_TIME,$TOTAL_RECOVERY_TIME,$READY_AFTER_CREATION,$RESTORE_TIME,$RESULT" \
    >> "$RESULTS_FILE"


# ============================================================
# 15. Report
# ============================================================

echo
echo "=========================================="
echo " Experiment Result"
echo "=========================================="

echo "Failed node:               $FAILED_NODE"

echo "Original Pod:              $ORIGINAL_POD"

echo "Replacement Pod:           $REPLACEMENT_POD"

echo "Initial replicas:          $EXPECTED_REPLICAS"

echo "Final replicas:            $FINAL_READY"

echo
echo "Failure detection:         ${DETECTION_TIME}s"

echo "Pod creation:              ${POD_CREATION_TIME}s"

echo "Pod Ready:                 ${TOTAL_RECOVERY_TIME}s"

echo "Ready after creation:      ${READY_AFTER_CREATION}s"

echo "Node restoration:          ${RESTORE_TIME}s"

echo
echo "Result:                    $RESULT"

echo "=========================================="


echo
echo "Results saved to:"
echo "$RESULTS_FILE"