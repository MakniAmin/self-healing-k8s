#!/bin/bash

NAMESPACE="self-healing"
SERVICE_URL="http://self-healing-service/"
RESULTS_DIR="chaos/results"
RESULTS_FILE="$RESULTS_DIR/network-traffic-results.csv"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$RESULTS_FILE" ]; then
    echo "timestamp,http_code,response_seconds,result" > "$RESULTS_FILE"
fi

echo "Recording HTTP traffic for 150 seconds..."
echo "CSV: $RESULTS_FILE"

END_TIME=$((SECONDS + 150))

while [ "$SECONDS" -lt "$END_TIME" ]; do
    OUTPUT=$(kubectl exec -n "$NAMESPACE" network-test -- \
        curl -sS -o /dev/null \
        -w "%{http_code},%{time_total}" \
        --max-time 3 \
        "$SERVICE_URL" 2>/dev/null)
    CURL_STATUS=$?

    TIMESTAMP=$(date -Iseconds)

    if [ "$CURL_STATUS" -eq 0 ]; then
        HTTP_CODE=${OUTPUT%%,*}
        RESPONSE_TIME=${OUTPUT#*,}
        RESULT="SUCCESS"
    else
        HTTP_CODE="000"
        RESPONSE_TIME="3"
        RESULT="FAILED"
    fi

    echo "$TIMESTAMP,$HTTP_CODE,$RESPONSE_TIME,$RESULT" \
        | tee -a "$RESULTS_FILE"

    sleep 1
done

echo "Traffic recording finished."