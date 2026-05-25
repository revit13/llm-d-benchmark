# EPD Pools Disaggregation — Shared Storage Quick Start

This guide walks through deploying the **encode / prefill / decode** disaggregated inference pipeline on an OpenShift cluster, then driving it locally via the coordinator.

## Prerequisites

- OpenShift cluster access with namespace-admin permissions on `<ns>`.
- `oc`, `docker`, `git`, `make`, `go` on your local machine.
- Python 3.11+ on your local machine.

---

## Step 1 — Log in to the OpenShift cluster

```bash
oc login --token=<your-token> --server=https://<cluster-api>:6443
oc whoami   # verify
```

---

## Step 2 — Clone the benchmark repo and install dependencies

```bash
git clone https://github.com/llm-d/llm-d-benchmark
cd llm-d-benchmark
```

Install the `llmdbenchmark` CLI and its dependencies into a local virtualenv:

```bash
./install.sh --no-uv     # use python -m venv; skip uv
source .venv/bin/activate
llmdbenchmark --version  # sanity check
```

---

## Step 3 — Deploy the EPD scenario on the cluster

This creates three InferencePools (encode / prefill / decode), each with its own
EPP, vLLM pod, HTTPRoute, and a shared PVC for the file-based EC + KV cache connectors.

```bash
NS=<your-namespace>

# Deploy all three stacks (encode → prefill → decode) in order.
# --non-admin skips cluster-scoped CRD installs (assumed already present).
llmdbenchmark --spec guides/epd-pools-disaggregation standup \
  -p "$NS" \
  --non-admin
```

Wait for all pods to be Ready:

```bash
oc get pods -n "$NS" -l 'llm-d.ai/role in (encode,prefill,decode)' -w
# Expect: 1/1 or 2/2 Running for each role
```



---

## Step 4 — Start local auxiliary services + coordinator

`run_epd_cluster.sh` starts everything your local machine needs:

| Service | Port | What it does |
|---------|------|-------------|
| Gateway port-forward | 8090 | Tunnels the cluster's Istio gateway to localhost; EPP-Phase header routing applies |
| vLLM render | 8000 | Encodes multimodal images into token sequences (runs in Docker) |
| Downloader 1 | 9000 | Serves `assets/dog1.jpg` as `/img.jpg` (test image) |
| Downloader 2 | 9001 | Serves `assets/dog2.jpg` as `/img2.jpg` (test image) |
| Coordinator | 8080 | Orchestrates the encode → prefill → decode pipeline; cloned from GitHub |

```bash
# Start everything (runs check → gateway → downloaders → render → coordinator)
./run_epd_cluster.sh all

# Check status at any time
./run_epd_cluster.sh status

# Tail coordinator log
tail -f /tmp/run_epd-pf/coordinator.log
```


---

## Step 5 — Send a test request

```bash
# Run the bundled two-image test payload through the full EPD pipeline
./curl_two_images.sh

# Or send manually:
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-VL-2B-Instruct",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "image_url", "image_url": {"url": "http://localhost:9000/img.jpg"}},
          {"type": "image_url", "image_url": {"url": "http://localhost:9001/img2.jpg"}},
          {"type": "text", "text": "Describe both images."}
        ]
      }
    ]
  }'
```

Expected: a JSON response with `choices[0].message.content` describing the images.

---

## Step 6 — Inspect shared cache activity

All three vLLM pods mount the `vllm-shared-storage` PVC at `/shared-cache`:

```bash
NS=<your-namespace>
POD=$(oc get pod -n $NS -l llm-d.ai/role=encode -o name | head -1)

# File sizes (bytes) per subdirectory
oc exec -n $NS $POD -c vllm -- du -sb /shared-cache/ec /shared-cache/kv

# Watch cache grow during a request
while true; do
  oc exec -n $NS $POD -c vllm -- du -sb /shared-cache/ec /shared-cache/kv 2>/dev/null
  sleep 1
done
```

After a successful request, `/shared-cache/ec` should contain encoder-cache files (written by encode, read by prefill) and `/shared-cache/kv` should contain KV-cache files (written by prefill, read by decode).

---

## Tear down

```bash
# Stop local services
./run_epd_cluster.sh stop

# Remove cluster resources
llmdbenchmark --spec guides/epd-pools-disaggregation teardown \
  -p "$NS" --non-admin
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `connection refused` on 8090 | Gateway PF died | `./run_epd_cluster.sh gateway` |
| `Only base64 data URLs are supported` from render | Downloaders not running or serving bad files | `./run_epd_cluster.sh downloader1 downloader2` — check `file /tmp/dog1.jpg` |
| `model ... does not exist` (404) | vLLM pod serving under suffixed name | Ensure `extraEnvVars.MODEL_NAME=Qwen/Qwen3-VL-2B-Instruct` is in scenario |
| Pods stuck `Pending` | Missing GPU or PVC not bound | `oc describe pod <pod>` → check events |
| SCC `FailedCreate` on pods | SCC rolebinding missing for pod SA | Script auto-patches after standup; re-run standup |
| `HMA enabled` vLLM crash | `ExampleConnector` incompatible with HMA | Ensure `--disable-hybrid-kv-cache-manager` in all `customCommand` blocks |
