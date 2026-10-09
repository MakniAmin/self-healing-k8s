# Chaos Experiment Results

## 1. Environment

- Kubernetes distribution: Kind
- Cluster: `devops-lab`
- Application namespace: `self-healing`
- Application: Nginx-based health-check application
- Replicas: 3
- Chaos testing: Chaos Mesh and custom test scripts
- Monitoring: Prometheus and Grafana

## 2. Pod Failure

Three recorded tests completed successfully.

| Run | Recovery time | Initial replicas | Final replicas | Result |
|---|---:|---:|---:|---|
| 1 | 6 s | 3 | 3 | PASS |
| 2 | 6 s | 3 | 3 | PASS |
| 3 | 6 s | 3 | 3 | PASS |

The Deployment maintained the desired replica count after the tested Pod failures.

## 3. Node Failure and Recovery Optimization

The following measurements compare the original configuration with the optimized configuration using 60-second `NoExecute` tolerations.

| Metric | Baseline | Optimized |
|---|---:|---:|
| Failure detection | 52 s | 49 s |
| Replacement Pod creation | 352 s | 109 s |
| Replacement Pod Ready | 359 s | 115 s |
| Ready after Pod creation | 7 s | 6 s |
| Node restoration | 2 s | 2 s |

The observed time until the replacement Pod became Ready decreased from 359 seconds to 115 seconds, approximately a **68% reduction**.

Calculation:

`((359 - 115) / 359) × 100 ≈ 68%`

The shorter tolerations improved recovery during the tested node-failure scenario. These results describe individual observed runs and are not a guarantee of identical recovery times in every environment.

## 4. Application Health Failure

- Test: temporarily remove the application's health file.
- Expected behavior: the `/health` probe fails, triggering container recovery through the configured liveness probe.
- Observed recovery time: 36 seconds.
- Container restart count: 2 → 3.
- Result: PASS.

**Important:** The test cleanup restores the health file. Restarting the container alone does not necessarily restore a file removed from the container's writable layer.

## 5. Network Packet Loss

Chaos Mesh injected 50% packet loss for 60 seconds against the selected application traffic.

- Chaos injection and recovery: completed successfully.
- Recorded HTTP 200 responses: 138.
- Recorded failed requests: 0.
- Average recorded latency: 1.044 ms.
- Maximum recorded latency: 2.094 ms.

The traffic recorder did not label individual measurements as baseline, injection, or recovery phases. Therefore, these results confirm successful HTTP responses during the recorded window, but do not establish that packet loss had no impact on latency or availability during the injection phase.

## 6. Container Process Failure

The main Nginx process was terminated with `SIGTERM` in one application container.

- Container restart count: 3 → 4.
- Time until Pod Ready was observed: 11 seconds.
- Application replicas: 3.
- Result: PASS.

The 11-second measurement includes command execution and polling overhead; it is not a pure measurement of Kubernetes recovery latency.

## 7. CI/CD Deployment

The GitHub Actions pipeline validates Kubernetes manifests, builds the application image, and deploys it to the local Kind cluster through a self-hosted runner.

The successful pipeline run completed in approximately 51 seconds.

Post-deployment verification showed:

- Deployment availability: 3/3 replicas.
- Application Pods: Running.
- Application health endpoint: HTTP 200.

## 8. Conclusion

The experiments demonstrated Kubernetes recovery from tested Pod, node, application-health, and container-process failures. The node-failure comparison showed a substantial improvement after reducing the configured toleration period. Chaos Mesh network testing and Prometheus/Grafana monitoring provide additional tools for evaluating cluster behavior.

Future improvements include repeated node-failure trials, phase-labelled network measurements, automated experiment result collection, and more precise separation of detection, scheduling, startup, and readiness times.