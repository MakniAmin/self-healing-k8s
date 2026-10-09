# Chaos Experiment Results

## Environment

- Kubernetes cluster: `devops-lab`
- Application namespace: `self-healing`
- Application: Nginx
- Deployment: `self-healing-app`
- Desired replicas: 3
- Chaos engineering tool: Chaos Mesh
- Monitoring: Prometheus and Grafana

## 1. Pod failure

**Objective:** Verify that Kubernetes replaces a failed application Pod and restores the desired replica count.

Recorded results in `pod-failure-results.csv`:

| Measurement | Result |
|---|---:|
| Initial replicas | 3 |
| Final replicas | 3 |
| Recorded recovery time | 6 seconds |

Three recorded runs report a recovery time of 6 seconds and a passing result.

## 2. Node failure and recovery optimization

**Objective:** Measure the effect of node-failure toleration settings on application recovery.

The following measurements are taken from the recorded runs in `node-failure-results-v4.csv`.

| Measurement | Baseline run | Optimized run |
|---|---:|---:|
| Failure detection | 52 s | 49 s |
| Replacement Pod creation | 352 s | 109 s |
| Replacement Pod Ready | 359 s | 115 s |
| Ready after creation | 7 s | 6 s |
| Node restoration | 2 s | 2 s |
| Result | PASS | PASS |

The optimized run reduced the observed time until the replacement Pod became Ready from 359 seconds to 115 seconds.

Percentage reduction:

\[
\frac{359-115}{359}\times100 \approx 68\%
\]

This is an observed result from these two runs, not a guarantee of identical recovery times in other environments.

The Deployment uses 60-second `NoExecute` tolerations for the `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable` taints. These settings affect eviction timing and involve a trade-off between faster recovery and tolerance of transient node connectivity problems.

## 3. Application health failure

**Objective:** Verify that a failing health endpoint causes Kubernetes to restart an unhealthy container.

Recorded result in `app-health-failure-results.csv`:

| Measurement | Result |
|---|---:|
| Initial container restarts | 2 |
| Final container restarts | 3 |
| Observed recovery time | 36 s |
| Result | PASS |

During the experiment, the health endpoint returned HTTP 404 after the health file was moved. The liveness probe failed, and Kubernetes restarted the Nginx container.

The experiment cleanup restored the health file. Container restart alone does not restore a file removed from the container's writable layer.

## 4. Network packet loss

**Objective:** Inject network packet loss and observe application traffic.

Chaos Mesh was configured to inject 50% packet loss for 60 seconds. The experiment status reported successful injection and recovery for the selected source and target Pods.

| Measurement | Result |
|---|---:|
| HTTP requests recorded | 138 |
| HTTP 200 responses | 138 |
| Recorded failed requests | 0 |
| Average observed response time | 1.044 ms |
| Maximum observed response time | 2.094 ms |

All 138 recorded requests returned HTTP 200.

**Interpretation:** the application remained reachable during the observation window. The CSV does not label requests by baseline, injection, and recovery phases, so it does not establish the latency impact of packet loss specifically during fault injection.

## 5. Container/process failure

**Objective:** Terminate the main process in one application container and observe Kubernetes recovery.

The Nginx container's main process was sent `SIGTERM`.

| Measurement | Result |
|---|---:|
| Initial restart count | 3 |
| Final restart count | 4 |
| Observed time until Ready condition | 11 s |
| Final application replicas | 3 |

The container restart count increased from 3 to 4, and `kubectl wait` observed the Pod becoming Ready after 11 seconds.

This measurement includes command execution and polling overhead; it is not an exact measurement of container restart latency.

## 6. CI/CD deployment verification

The GitHub Actions workflow completed successfully in a recorded run.

| Stage | Result |
|---|---|
| Required-file checks | Passed |
| Kubernetes manifest validation | Passed |
| Docker image build | Passed |
| Image loading into Kind | Passed |
| Kubernetes rollout verification | Passed |
| Application health check | Passed |
| Recorded workflow duration | 51 s |

After deployment, the Kubernetes Deployment reported three available replicas. A separate HTTP request to the service health endpoint returned HTTP 200.

## Conclusion

The experiments demonstrate Kubernetes recovery from Pod, node, application-health, and container-process failures. The node-failure comparison showed approximately 68% lower observed time to replacement-Pod readiness after adjusting node-failure tolerations.

The network experiment verified fault injection and recovery while all recorded HTTP requests succeeded, but phase-labeled traffic measurements are needed to quantify the impact of packet loss.

The CI/CD workflow automates manifest validation, image building, deployment to the local Kind cluster, rollout verification, and application health checking.
