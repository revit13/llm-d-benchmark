#!/bin/bash
# Usage: ./run_epd_cluster.sh [gateway|downloader1|downloader2|render|all|stop]
#   Defaults to 'all' if no stage is specified.
#
# This is the cluster variant of run_epd.sh: instead of running encode/
# prefill/decode locally OR port-forwarding to each pod individually, we
# port-forward the SINGLE cluster gateway service. The cluster's
# EPP-Phase HTTPRoutes (epp-phase-encode/prefill/decode) take care of
# routing each request to the right InferencePool based on the
# `EPP-Phase` header set by the coordinator.
#
# Local port mapping (matches what the coordinator config expects):
#   svc/infra-llmdbench-inference-gateway-istio:80  ->  localhost:8090
#   render container :8000                          ->  localhost:8000
#   downloader1 container :9000                     ->  localhost:9000
#   downloader2 container :9001                     ->  localhost:9001

STAGE="${1:-all}"
NS="${NS:-test-epd-pools}"
GATEWAY_SVC="${GATEWAY_SVC:-infra-llmdbench-inference-gateway-istio}"
GATEWAY_LOCAL_PORT="${GATEWAY_LOCAL_PORT:-8090}"
GATEWAY_REMOTE_PORT="${GATEWAY_REMOTE_PORT:-80}"
KUBECTL="${KUBECTL:-oc}"

# Auxiliary services still run as local Docker.
SHARED_DIR="/tmp/vllm-shared-cache"
mkdir -p "$SHARED_DIR/ec" "$SHARED_DIR/kv"

NETWORK="vllm-epd"
IMAGE="vllm/vllm-openai-cpu:latest"

PF_DIR="/tmp/run_epd-pf"
mkdir -p "$PF_DIR"

docker network create "$NETWORK" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Cluster gateway port-forward
# -----------------------------------------------------------------------------

start_pf() {
  local name="$1"; shift
  local target="$1"; shift   # e.g. svc/foo or pod/bar
  local pidfile="$PF_DIR/$name.pid"
  local logfile="$PF_DIR/$name.log"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[$name] already running (pid $(cat "$pidfile"))"
    return 0
  fi
  echo "[$name] Forwarding $target -> $* (log: $logfile)"
  nohup $KUBECTL -n "$NS" port-forward --address=0.0.0.0 "$target" "$@" \
    >"$logfile" 2>&1 &
  echo $! >"$pidfile"
  sleep 1
  if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[$name] port-forward failed; tail of log:"
    tail -20 "$logfile"
    rm -f "$pidfile"
    return 1
  fi
}

stop_pf() {
  local name="$1"
  local pidfile="$PF_DIR/$name.pid"
  if [ -f "$pidfile" ]; then
    local pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[$name] stopping port-forward (pid $pid)"
      kill "$pid"
    fi
    rm -f "$pidfile"
  fi
}

run_gateway() {
  start_pf gateway "svc/$GATEWAY_SVC" "$GATEWAY_LOCAL_PORT:$GATEWAY_REMOTE_PORT"
}

# -----------------------------------------------------------------------------
# Local Docker auxiliary services (unchanged from run_epd.sh)
# -----------------------------------------------------------------------------

run_downloader1() {
  echo "[downloader1] Starting on port 9000"
  docker run -d \
    --name vllm-downloader1 \
    --network "$NETWORK" \
    -p 9000:9000 \
    -v /tmp/dog1.jpg:/tmp/img.jpg:ro \
    python:3.10-slim \
    python3 -m http.server 9000 --directory /tmp
}

run_downloader2() {
  echo "[downloader2] Starting on port 9001"
  docker run -d \
    --name vllm-downloader2 \
    --network "$NETWORK" \
    -p 9001:9001 \
    -v /tmp/dog2.jpg:/tmp/img2.jpg:ro \
    python:3.10-slim \
    python3 -m http.server 9001 --directory /tmp
}

run_render() {
  echo "[render] Starting on port 8000"
  docker run -d \
    --name vllm-render \
    --shm-size=4g \
    --network "$NETWORK" \
    -p 8000:8000 \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    -e HF_TOKEN="$HF_TOKEN" \
    --entrypoint vllm \
    "$IMAGE" \
    launch render  Qwen/Qwen3-VL-2B-Instruct --port 8000
}

stop_all() {
  echo "[stop] Removing local Docker containers"
  docker rm -f vllm-downloader1 vllm-downloader2 vllm-render 2>/dev/null
  echo "[stop] Killing port-forwards"
  stop_pf gateway
  echo "All containers and port-forwards stopped."
}

case "$STAGE" in
  gateway)     run_gateway ;;
  downloader1) run_downloader1 ;;
  downloader2) run_downloader2 ;;
  render)      run_render ;;
  stop)        stop_all ;;
  all)
    run_gateway
    run_downloader1
    run_downloader2
    run_render
    echo "All stages started."
    echo "  Cluster gateway : http://localhost:$GATEWAY_LOCAL_PORT"
    echo "                    (routes by EPP-Phase header: encode|prefill|decode)"
    echo "  Render          : http://localhost:8000"
    echo "  Downloaders     : http://localhost:9000  http://localhost:9001"
    ;;
  *)
    echo "Unknown stage: $STAGE"
    echo "Usage: $0 [gateway|downloader1|downloader2|render|stop|all]"
    exit 1
    ;;
esac
