# Observability — Prometheus + Grafana

Deploys `kube-prometheus-stack` via Helm and wires it to CNPG's built-in `PodMonitor` to give live visibility into cluster health, replication lag, TPS, and failover events.

---

## What gets deployed

| Component | Purpose |
|---|---|
| Prometheus | Scrapes CNPG metrics via `PodMonitor` |
| Grafana | Visualizes cluster health — pre-loaded with the official CNPG dashboard |
| Prometheus Operator | Manages `PodMonitor` / `ServiceMonitor` CRDs |
| kube-state-metrics | Kubernetes object state metrics |
| node-exporter | Host-level CPU / memory / disk metrics |

---

## Files

| File | Purpose |
|---|---|
| `setup-monitoring.sh` | Installs the stack and verifies CNPG metrics are being scraped |
| `kube-prometheus-stack-values.yaml` | Helm values — tuned for Minikube (reduced resources, no persistent storage) |

---

## Prerequisites

- Helm v3 installed
- CNPG cluster running with `monitoring.enablePodMonitor: true` in the cluster manifest
- At least 4GB RAM free on the node — the stack is heavy alongside a 3-instance CNPG cluster

---

## Install

```bash
chmod +x monitoring/setup-monitoring.sh
./monitoring/setup-monitoring.sh
```

The script will:
1. Add the `prometheus-community` Helm repo
2. Install `kube-prometheus-stack` in the `monitoring` namespace
3. Verify the CNPG `PodMonitor` exists
4. Print port-forward commands to access Grafana and Prometheus

---

## Access Grafana

```bash
kubectl port-forward -n monitoring svc/prom-stack-grafana 3000:80
```

Open `http://localhost:3000` — login `admin / admin`

Navigate to **Dashboards → CloudNativePG → CloudNativePG** and set the dropdowns:
- **Operator Namespace** → `default`
- **Database Namespace** → `default`
- **Cluster** → `my-pg-cluster`

---

## Access Prometheus

```bash
kubectl port-forward -n monitoring svc/prom-stack-kube-prometheus-prometheus 9090:9090
```

Open `http://localhost:9090` and verify CNPG metrics are being scraped:

```
cnpg_collector_up
cnpg_pg_replication_lag
cnpg_backends_total
```

---

## Troubleshooting: PodMonitor not found

If `kubectl get podmonitor -A` returns nothing, the CNPG operator started before the Prometheus CRDs were installed and skipped PodMonitor creation. Fix:

```bash
kubectl rollout restart deployment -n cnpg-system cnpg-controller-manager
kubectl rollout status deployment -n cnpg-system cnpg-controller-manager
kubectl get podmonitor -A
```

The PodMonitor should appear within 30 seconds. Prometheus will begin scraping within the next minute.

---

## What the dashboard shows

**Health panel** — overall cluster state. Shows `Degraded` during a failover and returns to `Healthy` once the new primary is elected and all replicas have rejoined. This is the key indicator to watch during chaos tests.

**TPS (Transactions Per Second)** — live write throughput. During a write-during-failover test you can see the spike from the insert loop, the brief drop to zero during the election window (~1.7s), and the recovery once the new primary starts accepting writes.

**Replication lag** — streaming replication delay between primary and replicas in seconds. Should be 0s at steady state. Spikes briefly during a failover as the new primary catches up.

**Server Health table** — per-pod status showing `Up/Down`, clustering membership, active connections, wraparound risk, and start time. The start time column is particularly useful after chaos tests — it shows which pods have been recently restarted and confirms primary rotation across the cluster.

---

## Live failover captured in Grafana

Running `./cnpg-chaos-test.sh` or `./cnpg-write-failover.sh` while the dashboard is open (time range: Last 15 minutes, refresh: 5s) shows the full failover sequence in real time:

1. Health transitions from `Healthy` → `Replication Degraded` as the primary pod is killed
2. TPS drops to zero during the ~2s election window
3. A new pod appears in Server Health with start time "a few seconds ago"
4. Replication lag returns to 0s as replicas catch up
5. Health returns to `Healthy` once all three pods are clustered

The connection graphs in the Server Health table show the exact moment of failover as a step change on the timeline — visible evidence of the RTO measured by the chaos test scripts.