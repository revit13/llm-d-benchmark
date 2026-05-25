# Switch EC/KV connectors to ExampleConnector + add shared-cache PVC

## Context

Today the scenario at [config/scenarios/guides/epd-pools-disaggregation.yaml](config/scenarios/guides/epd-pools-disaggregation.yaml) wires NIXL transports between prefill and decode and `ECCPUConnector` for the encode→prefill encoder cache:

| Role | `--kv-transfer-config` | `--ec-transfer-config` |
|------|------------------------|------------------------|
| encode  | (none) | `{"ec_connector":"ECCPUConnector","ec_role":"ec_producer"}` |
| prefill | `{"kv_connector":"NixlConnector","kv_role":"kv_both"}` | `{"ec_connector":"ECCPUConnector","ec_role":"ec_consumer"}` |
| decode  | `{"kv_connector":"NixlConnector","kv_role":"kv_both"}` | (none) |

**Goal: swap BOTH the KV connector AND the EC connector per role to align with the local Docker reference at [/home/eres/run_epd.sh](file:///home/eres/run_epd.sh):**

- `--kv-transfer-config`: `NixlConnector` → `ExampleConnector` (file-based)
- `--ec-transfer-config`: `ECCPUConnector` → `ECExampleConnector` (file-based)
- Both connectors share a single mount at `/shared-cache`, with subdirs `/shared-cache/kv` (KV) and `/shared-cache/ec` (EC).

### Role assignment per phase

The two transfer configs each carry a **role** field (`kv_role` / `ec_role`) that decides who writes vs. reads the shared cache. With the swap to file-based connectors, the producer/consumer split is:

| Phase   | `kv_role`     | `ec_role`     | What it does                                                                |
|---------|---------------|---------------|-----------------------------------------------------------------------------|
| encode  | _(no kv flag)_ | `ec_producer` | Writes encoder cache to `/shared-cache/ec`, never touches KV.               |
| prefill | `kv_producer` | `ec_consumer` | Reads encoder cache from `/shared-cache/ec`, writes KV to `/shared-cache/kv`. |
| decode  | `kv_consumer` | _(no ec flag)_ | Reads KV from `/shared-cache/kv`, never touches encoder cache.              |

This mirrors the producer/consumer pairs in [run_epd.sh lines 83, 106-107, 130](file:///home/eres/run_epd.sh).

| Role | `--kv-transfer-config` | `--ec-transfer-config` |
|------|------------------------|------------------------|
| encode  | (none) | `{"ec_connector":"ECExampleConnector","ec_role":"ec_producer","ec_connector_extra_config":{"shared_storage_path":"/shared-cache/ec"}}` |
| prefill | `{"kv_connector":"ExampleConnector","kv_role":"kv_producer","kv_connector_extra_config":{"shared_storage_path":"/shared-cache/kv"}}` | `{"ec_connector":"ECExampleConnector","ec_role":"ec_consumer","ec_connector_extra_config":{"shared_storage_path":"/shared-cache/ec"}}` |
| decode  | `{"kv_connector":"ExampleConnector","kv_role":"kv_consumer","kv_connector_extra_config":{"shared_storage_path":"/shared-cache/kv"}}` | (none) |

Both `Example*` connectors exchange caches over a **shared filesystem** (`/shared-cache/{ec,kv}`) instead of NIXL/RDMA. Three pods writing/reading the same path → on a cluster that means a `ReadWriteMany` PVC mounted at `/shared-cache` in every pod. The reference chart at [/home/eres/llm-d/guides/e-dp-disaggregation/ec-cache.yaml](file:///home/eres/llm-d/guides/e-dp-disaggregation/ec-cache.yaml) and [/home/eres/llm-d/guides/e-dp-disaggregation/ms-e-dp-disaggregation/values.yaml](file:///home/eres/llm-d/guides/e-dp-disaggregation/ms-e-dp-disaggregation/values.yaml) already does this for its (combined) encode + prefillDecode setup; we lift the same pattern to our 3-role layout.

User-confirmed:
- Shared storage = a new RWX PVC `vllm-shared-storage` (50 Gi, storage class `local-fs`).
- The cluster vLLM image already carries `ECExampleConnector` / `ExampleConnector` — no python file mounts needed.

---

## Files to modify

| File | Change |
|------|-------|
| [config/scenarios/guides/epd-pools-disaggregation.yaml](config/scenarios/guides/epd-pools-disaggregation.yaml) | (a) Replace the connector flags in each role's `customCommand`. (b) Add a shared `vllmCommon.volumes`/`volumeMounts` entry that binds `/shared-cache` to the PVC. (c) Prepend `mkdir -p /shared-cache/{ec,kv}` to each `customCommand`. |
| Same scenario `shared.storage.extraPvc` block | Declares a 50 Gi RWX PVC `vllm-shared-storage` on storage class `local-fs`. The existing template [config/templates/jinja/16_pvc_extra-pvc.yaml.j2](config/templates/jinja/16_pvc_extra-pvc.yaml.j2) already handles `storage.extraPvc` and standup step 04 (`_create_extra_pvc` in [llmdbenchmark/standup/steps/step_04_model_namespace.py](llmdbenchmark/standup/steps/step_04_model_namespace.py)) applies it before the helm releases. No manual `oc apply` needed. |

No template (`.j2`) or Python changes — `vllmCommon.volumes` already plumbs through to the modelservice chart values via [config/templates/jinja/13_ms-values.yaml.j2 lines 521-554](config/templates/jinja/13_ms-values.yaml.j2#L521-L554), and `type: persistentVolumeClaim` is supported.

---

## Approach

### 1. Connector flags — per role `customCommand`

Edit each `vllm.customCommand` in [config/scenarios/guides/epd-pools-disaggregation.yaml](config/scenarios/guides/epd-pools-disaggregation.yaml).

**encode** (~line 195):
- Replace
  `--ec-transfer-config '{"ec_connector":"ECCPUConnector","ec_role":"ec_producer"}'`
  with
  `--ec-transfer-config '{"ec_connector":"ECExampleConnector","ec_role":"ec_producer","ec_connector_extra_config":{"shared_storage_path":"/shared-cache/ec"}}'`
- Keep `--mm-encoder-only` and `--no-enable-prefix-caching`.

**prefill** (~lines 316-317):
- Replace
  `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'`
  with
  `--kv-transfer-config '{"kv_connector":"ExampleConnector","kv_role":"kv_producer","kv_connector_extra_config":{"shared_storage_path":"/shared-cache/kv"}}'`
- Replace
  `--ec-transfer-config '{"ec_connector":"ECCPUConnector","ec_role":"ec_consumer"}'`
  with
  `--ec-transfer-config '{"ec_connector":"ECExampleConnector","ec_role":"ec_consumer","ec_connector_extra_config":{"shared_storage_path":"/shared-cache/ec"}}'`

**decode** (~line 408):
- Replace
  `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'`
  with
  `--kv-transfer-config '{"kv_connector":"ExampleConnector","kv_role":"kv_consumer","kv_connector_extra_config":{"shared_storage_path":"/shared-cache/kv"}}'`
- No `--ec-transfer-config` for decode.

Prepend to **each** of the three `customCommand` blocks (after `source /shared-config/llmdbench_env.sh`, before `vllm serve …`):

```bash
mkdir -p /shared-cache/ec /shared-cache/kv
```

### 2. Shared-cache PVC mount — extend `shared.vllmCommon`

Append to the existing `vllmCommon.volumes` and `vllmCommon.volumeMounts` arrays (currently around lines 147-161):

```yaml
  vllmCommon:
    volumes:
      - name: shared-config
        type: emptyDir
        emptyDir: {}
      - name: dshm
        type: emptyDir
        emptyDir:
          medium: Memory
          sizeLimit: 16Gi
      # NEW
      - name: shared-cache
        type: persistentVolumeClaim
        persistentVolumeClaim:
          claimName: vllm-shared-storage

    volumeMounts:
      - name: shared-config
        mountPath: /shared-config
      - name: dshm
        mountPath: /dev/shm
      # NEW
      - name: shared-cache
        mountPath: /shared-cache
```

Volumes propagate to all three role pods automatically; no template change needed.

### 3. PVC manifest — auto-rendered by standup

Add to the scenario's `shared.storage` block (alongside the existing `modelPvc`):

```yaml
storage:
  modelPvc:
    size: 1Ti
  extraPvc:
    name: vllm-shared-storage
    size: 50Gi
    storageClassName: local-fs
    accessModes:
      - ReadWriteMany
```

This drives the existing [config/templates/jinja/16_pvc_extra-pvc.yaml.j2](config/templates/jinja/16_pvc_extra-pvc.yaml.j2) template which renders into each stack's `16_pvc_extra-pvc.yaml`. Standup step 04 (`_create_extra_pvc` in [llmdbenchmark/standup/steps/step_04_model_namespace.py](llmdbenchmark/standup/steps/step_04_model_namespace.py)) `oc apply`s it once per stack — second/third applies are no-ops because the PVC already exists. **No `oc apply` step required of the operator.**

### 4. Permissions

Pods currently run with `runAsUser: 0` and the `privileged` SCC, so root can write the mount — no `fix-permissions` initContainer needed in the first pass. The `mkdir -p` from §1 ensures the `/ec` and `/kv` subdirs exist before vLLM starts.

If we ever drop `runAsUser: 0`, add an initContainer per role:

```yaml
- name: fix-permissions
  image: busybox:latest
  command: ["sh", "-c", "mkdir -p /shared-cache/ec /shared-cache/kv && chmod -R 2775 /shared-cache"]
  securityContext:
    runAsUser: 0
    privileged: true
  volumeMounts:
    - name: shared-cache
      mountPath: /shared-cache
```

---

## Existing utilities reused

- `vllmCommon.volumes` / `vllmCommon.volumeMounts` flow into ms-values via [config/templates/jinja/13_ms-values.yaml.j2:497-554](config/templates/jinja/13_ms-values.yaml.j2#L497-L554) for all three roles. PVC support already exists.
- `shared:` block merges into each stack's root via the existing scenario merge in [llmdbenchmark/parser/render_plans.py](llmdbenchmark/parser/render_plans.py). Volumes appear in all 3 stacks automatically.
- `customCommand` is passed verbatim by the chart's `_helpers.tpl` `command` definition; only the YAML string changes.

No new functions, new templates, or chart logic.

---

## Verification

1. **PVC bound after standup**:
   ```bash
   # standup step 04 creates the PVC -- after standup, confirm it bound
   oc get pvc vllm-shared-storage -n test-epd-pools \
     -o jsonpath='{.status.phase} {.status.capacity.storage} {.spec.storageClassName}'; echo
   ```
   Expected: `Bound 50Gi local-fs`. (storage class `local-fs` uses `WaitForFirstConsumer`, so the PVC may stay `Pending` until the first pod that mounts it schedules — that's fine.)

2. **Render-only check** — confirm flags + volumes look right in the rendered ms-values:
   ```bash
   llmdbenchmark --spec guides/epd-pools-disaggregation --dry-run standup -p test-epd-pools --non-admin
   WS=$(ls -td /tmp/workspace_llmdbench_*/eres-* | head -1)
   for s in epd-encode epd-prefill epd-decode; do
     echo "=== $s ms-values ==="
     grep -E "ec-transfer-config|kv-transfer-config|shared-cache|persistentVolumeClaim|claimName" \
       "$WS/plan/$s/13_ms-values.yaml" | head -10
   done
   ```
   Expected per role: correct `ec_role`/`kv_role` strings, plus `claimName: vllm-shared-storage` and `mountPath: /shared-cache` once each.

3. **Live deploy** — full teardown + standup:
   ```bash
   llmdbenchmark --spec guides/epd-pools-disaggregation teardown -p test-epd-pools --non-admin
   llmdbenchmark --spec guides/epd-pools-disaggregation standup  -p test-epd-pools --non-admin
   ```

4. **Pod sees the mount**:
   ```bash
   for ROLE in encode prefill decode; do
     POD=$(oc get pod -n test-epd-pools -l llm-d.ai/role=$ROLE -o name | head -1)
     echo "=== $ROLE: $POD ==="
     oc exec -n test-epd-pools $POD -c vllm -- sh -c 'ls -la /shared-cache && mount | grep shared-cache'
   done
   ```

5. **Connector handshake** — vLLM logs at startup:
   ```bash
   for ROLE in encode prefill decode; do
     POD=$(oc get pod -n test-epd-pools -l llm-d.ai/role=$ROLE -o name | head -1)
     echo "=== $ROLE ==="
     oc logs -n test-epd-pools $POD -c vllm --tail=200 \
       | grep -iE "ec_connector|kv_connector|ECExampleConnector|ExampleConnector|shared_storage_path"
   done
   ```
   Expected: lines per role showing `ECExampleConnector` and/or `ExampleConnector` initialized with `/shared-cache/{ec,kv}`.

6. **End-to-end via the coordinator** — drive a full pipeline and confirm cache files appear under the PVC:
   ```bash
   POD=$(oc get pod -n test-epd-pools -l llm-d.ai/role=encode -o name | head -1)
   oc exec -n test-epd-pools $POD -c vllm -- sh -c 'ls -la /shared-cache/ec /shared-cache/kv 2>/dev/null'
   # send a request through the coordinator, then re-list — new entries should appear.
   ```

---

## Risks & notes

- **PVC must be RWX.** `local-fs` on this cluster supports RWX (per [/home/eres/llm-d/guides/e-dp-disaggregation/ec-cache.yaml](file:///home/eres/llm-d/guides/e-dp-disaggregation/ec-cache.yaml)). Verify in step 1 — if `Phase` stays `Pending`, the storage class doesn't actually offer RWX and we need a different SC.
- **`runAsUser: 0` already in scenario.** Removing it later requires the `fix-permissions` initContainer described in §4.
- **`mkdir -p` prepend in customCommand.** Small but visible churn. Cleaner alternatives (one-time Job, initContainer) add ordering complexity for little benefit.
- **Connector availability assumption.** If pods crash with "unknown connector" on startup, fall back to mounting the python file via a ConfigMap into `/opt/venv/lib/python3.12/site-packages/vllm/distributed/kv_transfer/kv_connector/v1/example_connector.py` — would add a ConfigMap manifest under `config/templates/jinja/` and `additionalVolume(Mount)` entries per role.
- **EPP-Phase HTTPRoute (prior change) is unaffected** — header-based routing is orthogonal to the in-pod connector swap.
