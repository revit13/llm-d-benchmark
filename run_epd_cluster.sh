#!/bin/bash
# run_epd_cluster.sh — local launcher for the EPD coordinator pipeline,
# with the encode/prefill/decode vLLM pods running on a remote OpenShift
# (or Kubernetes) cluster, and auxiliary services (gateway port-forward,
# image downloaders, vLLM render) running on this host.
#
# Topology:
#
#   ┌──────────── this host ────────────┐         ┌──── cluster ────┐
#   │                                   │         │                 │
#   │  coordinator (make run)           │         │  gateway        │
#   │     │                             │  PF     │   │             │
#   │     ├──► localhost:8090 ──────────┼─────────►   │             │
#   │     ├──► localhost:8000  (render) │  8090   │   ▼             │
#   │     ├──► localhost:9000  (img1)   │         │  HTTPRoute      │
#   │     └──► localhost:9001  (img2)   │         │  (EPP-Phase     │
#   │                                   │         │   header)       │
#   └───────────────────────────────────┘         │   │             │
#                                                 │   ├─encode pod  │
#                                                 │   ├─prefill pod │
#                                                 │   └─decode pod  │
#                                                 └─────────────────┘
#
# The cluster's HTTPRoute fans out by the `EPP-Phase` request header that
# the coordinator sets on each phase, so this host only needs ONE forward
# (the gateway).
#
# ┌─ Prerequisites ─────────────────────────────────────────────────────┐
# │ - docker  (or podman with `alias docker=podman`)                    │
# │ - oc      (kubectl works too — set KUBECTL=kubectl)                 │
# │ - curl                                                              │
# │ - You are logged in to the cluster:    oc whoami                    │
# │ - The EPD scenario is already deployed in $NS:                      │
# │     llmdbenchmark --spec guides/epd-pools-disaggregation \          │
# │       standup -p $NS --non-admin                                    │
# │   (See repo: /home/eres/llm-d-benchmark.)                           │
# │ - HF_TOKEN env var: optional. Needed only if Qwen3-VL-2B-Instruct   │
# │   weights aren't already in ~/.cache/huggingface (first render run).│
# └─────────────────────────────────────────────────────────────────────┘
#
# Usage:
#   ./run_epd_cluster.sh [check|all|gateway|downloader1|downloader2|render|status|stop]
#
# Stages:
#   check        Run preflight (deps, cluster login, gateway service exist)
#   all          (default) check → start everything
#   gateway      port-forward the cluster gateway service to localhost
#   downloader1  serve /tmp/dog1.jpg   on localhost:9000/img.jpg
#   downloader2  serve /tmp/dog2.jpg   on localhost:9001/img2.jpg
#   render       run vLLM 'launch render' on localhost:8000 (multimodal preprocess)
#   status       show what's running (docker + port-forward + listening ports)
#   stop         tear down everything started by this script
#
# Env-var overrides (all optional):
#   NS                  cluster namespace (default: test-epd-pools)
#   GATEWAY_SVC         gateway service name (default: infra-llmdbench-inference-gateway-istio)
#   GATEWAY_LOCAL_PORT  local port for gateway PF (default: 8090)
#   GATEWAY_REMOTE_PORT cluster port (default: 80)
#   KUBECTL             kubectl/oc binary (default: oc)
#   IMAGE               local vLLM image (default: vllm/vllm-openai-cpu:latest)
#   HF_TOKEN            forwarded to the render container if set
#   DOG1, DOG2          host file paths for the test images
#                       (defaults: /tmp/dog1.jpg and /tmp/dog2.jpg,
#                        seeded from assets/ next to this script)
#   COORDINATOR_REPO    git URL (default: https://github.com/llm-d-incubation/coordinator)
#   COORDINATOR_DIR     local checkout (default: /tmp/epd-coordinator)
#   COORDINATOR_REF     branch/tag/commit to check out (default: main)
#   COORDINATOR_CONFIG  path under $COORDINATOR_DIR (default: configs/coordinator.yaml)
#   COORDINATOR_PULL    set to 1 to git-fetch+rebase on each run (default: 0)

set -u

STAGE="${1:-all}"

# ---- Configurable env ------------------------------------------------------
NS="${NS:-test-epd-pools}"
GATEWAY_SVC="${GATEWAY_SVC:-infra-llmdbench-inference-gateway-istio}"
GATEWAY_LOCAL_PORT="${GATEWAY_LOCAL_PORT:-8090}"
GATEWAY_REMOTE_PORT="${GATEWAY_REMOTE_PORT:-80}"
KUBECTL="${KUBECTL:-oc}"
IMAGE="${IMAGE:-vllm/vllm-openai-cpu:latest}"
DOG1="${DOG1:-/tmp/dog1.jpg}"
DOG2="${DOG2:-/tmp/dog2.jpg}"

COORDINATOR_REPO="${COORDINATOR_REPO:-https://github.com/llm-d-incubation/coordinator}"
COORDINATOR_DIR="${COORDINATOR_DIR:-/tmp/epd-coordinator}"
COORDINATOR_REF="${COORDINATOR_REF:-main}"
COORDINATOR_CONFIG="${COORDINATOR_CONFIG:-configs/coordinator.yaml}"
COORDINATOR_PULL="${COORDINATOR_PULL:-0}"

# Bundled sample images shipped alongside this script in assets/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLED_DOG1="$SCRIPT_DIR/assets/dog1.jpg"
BUNDLED_DOG2="$SCRIPT_DIR/assets/dog2.jpg"

NETWORK="vllm-epd"
SHARED_DIR="/tmp/vllm-shared-cache"
PF_DIR="/tmp/run_epd-pf"

mkdir -p "$SHARED_DIR/ec" "$SHARED_DIR/kv" "$PF_DIR"

# ---- Helpers ---------------------------------------------------------------

log()  { printf "\033[1;34m[%s]\033[0m %s\n" "${2:-info}" "$1"; }
warn() { printf "\033[1;33m[%s]\033[0m %s\n" "${2:-warn}" "$1" >&2; }
die()  { printf "\033[1;31m[%s]\033[0m %s\n" "${2:-error}" "$1" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Ensure PATH is a valid image file before Docker bind-mounts it.
# Priority: 1) already valid on host  2) bundled in assets/  3) 1x1 placeholder.
ensure_image_file() {
  local path="$1"
  local bundled="$2"
  if [ -d "$path" ] || [ ! -s "$path" ]; then
    rm -rf "$path"
    if [ -f "$bundled" ] && [ -s "$bundled" ]; then
      log "  copying bundled image $bundled -> $path"
      cp "$bundled" "$path"
    else
      warn "$path missing and no bundled image found -- using 1x1 PNG placeholder"
      base64 -d > "$path" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=
PNG
    fi
  fi
}

start_pf() {
  local name="$1"; shift
  local target="$1"; shift
  local pidfile="$PF_DIR/$name.pid"
  local logfile="$PF_DIR/$name.log"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "[$name] already running (pid $(cat "$pidfile"))"
    return 0
  fi
  log "[$name] Forwarding $target -> $* (log: $logfile)"
  nohup "$KUBECTL" -n "$NS" port-forward --address=0.0.0.0 "$target" "$@" \
    >"$logfile" 2>&1 &
  echo $! >"$pidfile"
  sleep 1
  if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    warn "[$name] port-forward failed; tail of log:"
    tail -20 "$logfile" >&2
    rm -f "$pidfile"
    return 1
  fi
}

stop_pf() {
  local name="$1"
  local pidfile="$PF_DIR/$name.pid"
  if [ -f "$pidfile" ]; then
    local pid; pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      log "[$name] stopping port-forward (pid $pid)"
      kill "$pid"
    fi
    rm -f "$pidfile"
  fi
}

# ---- check / preflight -----------------------------------------------------

run_check() {
  log "[check] verifying tools"
  require_cmd docker
  require_cmd "$KUBECTL"
  require_cmd curl

  log "[check] cluster login"
  if ! "$KUBECTL" whoami >/dev/null 2>&1; then
    die "$KUBECTL whoami failed -- run 'oc login --token=... --server=...' first"
  fi
  log "  user: $($KUBECTL whoami)"

  log "[check] namespace $NS exists and is reachable"
  if ! "$KUBECTL" get ns "$NS" >/dev/null 2>&1; then
    die "namespace '$NS' not found (set NS=... or run llmdbenchmark standup first)"
  fi

  log "[check] gateway service $GATEWAY_SVC exists in $NS"
  if ! "$KUBECTL" get svc "$GATEWAY_SVC" -n "$NS" >/dev/null 2>&1; then
    die "service '$GATEWAY_SVC' not found in $NS -- has the EPD scenario been deployed?
  Try:  llmdbenchmark --spec guides/epd-pools-disaggregation standup -p $NS --non-admin"
  fi

  log "[check] HF_TOKEN"
  if [ -z "${HF_TOKEN:-}" ]; then
    warn "HF_TOKEN is empty. The render container won't be able to download Qwen3-VL-2B-Instruct
       on first run unless the weights are already in ~/.cache/huggingface."
  fi

  log "[check] preflight ok"
}

# ---- start each piece ------------------------------------------------------

run_gateway() {
  start_pf gateway "svc/$GATEWAY_SVC" "$GATEWAY_LOCAL_PORT:$GATEWAY_REMOTE_PORT"
}

run_downloader1() {
  ensure_image_file "$DOG1" "$BUNDLED_DOG1"
  log "[downloader1] starting on :9000 (serving $DOG1 as /img.jpg)"
  docker rm -f vllm-downloader1 2>/dev/null || true
  docker run -d \
    --name vllm-downloader1 \
    --network "$NETWORK" \
    -p 9000:9000 \
    -v "$DOG1":/tmp/img.jpg:ro \
    python:3.10-slim \
    python3 -m http.server 9000 --directory /tmp >/dev/null
}

run_downloader2() {
  ensure_image_file "$DOG2" "$BUNDLED_DOG2"
  log "[downloader2] starting on :9001 (serving $DOG2 as /img2.jpg)"
  docker rm -f vllm-downloader2 2>/dev/null || true
  docker run -d \
    --name vllm-downloader2 \
    --network "$NETWORK" \
    -p 9001:9001 \
    -v "$DOG2":/tmp/img2.jpg:ro \
    python:3.10-slim \
    python3 -m http.server 9001 --directory /tmp >/dev/null
}

run_render() {
  log "[render] starting on :8000 (image: $IMAGE)"
  docker rm -f vllm-render 2>/dev/null || true
  docker run -d \
    --name vllm-render \
    --shm-size=4g \
    --network "$NETWORK" \
    -p 8000:8000 \
    -v "$HOME/.cache/huggingface":/root/.cache/huggingface \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    --entrypoint vllm \
    "$IMAGE" \
    launch render Qwen/Qwen3-VL-2B-Instruct --port 8000 \
    >/dev/null
  warn "render is loading the model on first start; tail with:  docker logs -f vllm-render"
}

# ---- coordinator -----------------------------------------------------------

run_coordinator() {
  require_cmd git
  require_cmd make
  require_cmd go

  local pidfile="$PF_DIR/coordinator.pid"
  local logfile="$PF_DIR/coordinator.log"

  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "[coordinator] already running (pid $(cat "$pidfile"))"
    return 0
  fi

  if [ ! -d "$COORDINATOR_DIR/.git" ]; then
    log "[coordinator] cloning $COORDINATOR_REPO -> $COORDINATOR_DIR"
    git clone "$COORDINATOR_REPO" "$COORDINATOR_DIR" \
      || die "git clone failed for $COORDINATOR_REPO"
    if [ -n "$COORDINATOR_REF" ] && [ "$COORDINATOR_REF" != "main" ]; then
      ( cd "$COORDINATOR_DIR" && git checkout "$COORDINATOR_REF" ) \
        || die "git checkout $COORDINATOR_REF failed"
    fi
  elif [ "$COORDINATOR_PULL" = "1" ]; then
    log "[coordinator] updating $COORDINATOR_DIR (COORDINATOR_PULL=1)"
    ( cd "$COORDINATOR_DIR" \
        && git fetch --quiet origin "$COORDINATOR_REF" \
        && git checkout "$COORDINATOR_REF" \
        && git pull --rebase --quiet ) \
      || warn "git pull failed; continuing with existing checkout"
  else
    log "[coordinator] using existing checkout at $COORDINATOR_DIR ($(cd "$COORDINATOR_DIR" && git rev-parse --short HEAD 2>/dev/null || echo '?'))"
  fi

  if [ ! -f "$COORDINATOR_DIR/$COORDINATOR_CONFIG" ]; then
    die "config not found: $COORDINATOR_DIR/$COORDINATOR_CONFIG"
  fi

  # Patch the config to use localhost endpoints instead of K8s service DNS
  # names (rendering-service, envoy-gateway) that the default config ships with.
  # We write a patched copy so the original is not modified.
  local patched_config="$PF_DIR/coordinator.yaml"
  sed \
    -e "s|http://rendering-service:[0-9]*|http://localhost:8000|g" \
    -e "s|http://envoy-gateway:[0-9]*|http://localhost:$GATEWAY_LOCAL_PORT|g" \
    -e "s|http://envoy-gateway\b|http://localhost:$GATEWAY_LOCAL_PORT|g" \
    -e "s|^log_level:.*|log_level: 5|" \
    "$COORDINATOR_DIR/$COORDINATOR_CONFIG" > "$patched_config"
  log "[coordinator] config patched -> $patched_config"
  log "             rendering_service: http://localhost:8000"
  log "             gateway:           http://localhost:$GATEWAY_LOCAL_PORT"
  log "             log_level:         5 (trace)"

  log "[coordinator] starting 'make run' (config: $patched_config, log: $logfile)"
  ( cd "$COORDINATOR_DIR" \
      && nohup make run COORDINATOR_CONFIG="$patched_config" \
           >"$logfile" 2>&1 & echo $! >"$pidfile" )
  sleep 2
  if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    warn "[coordinator] failed to start; tail of log:"
    tail -30 "$logfile" >&2
    rm -f "$pidfile"
    return 1
  fi
  log "[coordinator] running (pid $(cat "$pidfile")) -- http://localhost:8080"
}

stop_coordinator() {
  local pidfile="$PF_DIR/coordinator.pid"
  if [ -f "$pidfile" ]; then
    local pid; pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      log "[coordinator] stopping pid $pid"
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
  pkill -f "coordinator/configs/coordinator.yaml" 2>/dev/null || true
}

# ---- status ----------------------------------------------------------------

run_status() {
  echo "--- listening local ports ---"
  ss -lntp 2>/dev/null \
    | awk -v p="$GATEWAY_LOCAL_PORT" '$4 ~ ":(8000|9000|9001|"p")$"'
  echo
  echo "--- port-forward pidfiles ---"
  for f in "$PF_DIR"/*.pid; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .pid); pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then
      printf "  ok  %-12s pid %s\n" "$name" "$pid"
    else
      printf "  --  %-12s pid %s (dead, stale)\n" "$name" "$pid"
    fi
  done
  echo
  echo "--- docker containers ---"
  docker ps --filter name=vllm- --format '  {{.Names}}\t{{.Status}}'
  echo
  echo "--- HTTP probes ---"
  for u in "http://localhost:$GATEWAY_LOCAL_PORT" \
           "http://localhost:8000/v1/models" \
           "http://localhost:9000/img.jpg" \
           "http://localhost:9001/img2.jpg"; do
    code=$(curl -sk -o /dev/null --max-time 2 -w "%{http_code}" "$u" 2>/dev/null)
    [ -z "$code" ] && code="REFUSED"
    printf "  %s  %s\n" "$code" "$u"
  done
}

# ---- stop ------------------------------------------------------------------

stop_all() {
  log "[stop] removing local Docker containers"
  docker rm -f vllm-downloader1 vllm-downloader2 vllm-render 2>/dev/null || true
  log "[stop] stopping coordinator"
  stop_coordinator
  log "[stop] killing port-forwards"
  for f in "$PF_DIR"/*.pid; do
    [ -e "$f" ] || continue
    stop_pf "$(basename "$f" .pid)"
  done
  log "[stop] done"
}

# ---- main ------------------------------------------------------------------

# Make sure the docker network exists before any docker run
docker network create "$NETWORK" >/dev/null 2>&1 || true

case "$STAGE" in
  check)       run_check ;;
  gateway)     run_check && run_gateway ;;
  downloader1) run_check && run_downloader1 ;;
  downloader2) run_check && run_downloader2 ;;
  render)      run_check && run_render ;;
  coordinator) run_check && run_coordinator ;;
  status)      run_status ;;
  stop)        stop_all ;;
  all)
    run_check
    run_gateway
    run_downloader1
    run_downloader2
    run_render
    run_coordinator
    echo
    log "all stages started."
    echo "  cluster gateway : http://localhost:$GATEWAY_LOCAL_PORT"
    echo "                    (routes by EPP-Phase header: encode | prefill | decode)"
    echo "  render          : http://localhost:8000"
    echo "  downloaders     : http://localhost:9000  http://localhost:9001"
    echo "  coordinator     : http://localhost:8080  (logs: $PF_DIR/coordinator.log)"
    ;;
  -h|--help|help)
    grep -E '^# ' "$0" | sed -E 's/^# ?//'
    ;;
  *)
    die "unknown stage: $STAGE
Usage: $0 [check|all|gateway|downloader1|downloader2|render|coordinator|status|stop|help]"
    ;;
esac
