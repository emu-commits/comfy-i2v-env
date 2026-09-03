#!/usr/bin/env bash
# Capture a ComfyUI node schema from an image, without a GPU.
#
# /object_info is the authoritative description of every node this build can
# run: exact input names, types, defaults, min/max, and required-vs-optional.
# Anything that consumes a workflow needs it, and reading it out of the image
# is the only way to be sure it describes the build that will actually run.
#
# This also serves as a boot test. An image whose ComfyUI does not come up is
# broken regardless of what the security scan says, and it is much cheaper to
# discover that here than on rented hardware.
#
# Usage: dump-object-info.sh <image> <output.json>

set -euo pipefail

IMAGE="${1:?usage: dump-object-info.sh <image> <output.json>}"
OUT="${2:?usage: dump-object-info.sh <image> <output.json>}"
PORT="${PORT:-8188}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
NAME="objinfo-$$"

# Nodes this image exists to run. Their absence is a build failure, not a
# curiosity: a schema dump that is missing them would still be valid JSON and
# would still pass every structural check downstream.
REQUIRED_NODES="UNETLoader CLIPLoader VAELoader LoraLoaderModelOnly
                KSamplerAdvanced ModelSamplingSD3 CLIPTextEncode VAEDecode
                WanImageToVideo WanVaceToVideo TrimVideoLatent
                WanFirstLastFrameToVideo LoadImage SaveImage"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "${STUBS:-}" "${INPUTS:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Loader nodes enumerate models/ to build their choice lists, so a schema
# captured against an empty tree describes no real filename. Stub the files in
# so the recording describes a provisioned host. See tools/stub-models.txt.
STUBS="$(mktemp -d)"
STUB_COUNT=0
while IFS= read -r rel; do
  case "$rel" in ''|\#*) continue ;; esac
  mkdir -p "$STUBS/$(dirname "$rel")"
  : > "$STUBS/$rel"
  STUB_COUNT=$((STUB_COUNT + 1))
done < "$(dirname "$0")/stub-models.txt"
echo "staged $STUB_COUNT model placeholders"

INPUTS="$(mktemp -d)"
INPUT_COUNT=0
while IFS= read -r rel; do
  case "$rel" in ''|\#*) continue ;; esac
  mkdir -p "$INPUTS/$(dirname "$rel")"
  : > "$INPUTS/$rel"
  INPUT_COUNT=$((INPUT_COUNT + 1))
done < "$(dirname "$0")/stub-inputs.txt"
echo "staged $INPUT_COUNT input placeholders"

echo "starting $IMAGE on CPU..."
# models/ is empty in the image, so mounting over it loses nothing. input/ is
# NOT empty -- ComfyUI ships example.png, and LoadImage's choices come from that
# directory -- so the placeholders are copied in rather than mounted over. A
# mount there silently deletes a file every stock workflow refers to.
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:${PORT}" \
  -v "$STUBS:/opt/ComfyUI/models:ro" \
  -v "$INPUTS:/opt/stub-inputs:ro" "$IMAGE" \
  sh -c "cp -n /opt/stub-inputs/* /opt/ComfyUI/input/ 2>/dev/null; \
         exec python main.py --cpu --listen 0.0.0.0 --port ${PORT} \
              --disable-auto-launch --disable-metadata" >/dev/null

deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/object_info" -o "$OUT" 2>/dev/null; do
  if ! docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; then
    echo "FAIL: container exited before serving. Last 60 lines:" >&2
    docker logs --tail 60 "$NAME" >&2 || true
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FAIL: ComfyUI did not serve /object_info within ${BOOT_TIMEOUT}s. Last 60 lines:" >&2
    docker logs --tail 60 "$NAME" >&2 || true
    exit 1
  fi
  sleep 3
done

curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/system_stats" -o "${OUT%.json}-system.json" || true

# A 200 with a plausible body is not proof the body is the thing we wanted.
python3 - "$OUT" "$REQUIRED_NODES" <<'PY'
import json, sys
path, required = sys.argv[1], sys.argv[2].split()
with open(path) as fh:
    info = json.load(fh)
if not isinstance(info, dict) or not info:
    sys.exit(f"FAIL: {path} is not a non-empty object")
missing = [n for n in required if n not in info]
if missing:
    sys.exit(f"FAIL: image is missing required nodes: {', '.join(missing)}")

# The placeholders are only useful if they reached the enumeration. An empty
# choice list here means the schema cannot check any workflow naming a weight,
# and it would look exactly like a successful capture.
def choices(node, field):
    spec = info.get(node, {}).get("input", {}).get("required", {}).get(field)
    if isinstance(spec, list) and spec:
        head = spec[0]
        if isinstance(head, list):
            return head
        if len(spec) > 1 and isinstance(spec[1], dict):
            return spec[1].get("options") or []
    return []

for node, field, want in (
    ("UNETLoader", "unet_name", "fun_vace"),
    ("VAELoader", "vae_name", "wan_2.1_vae"),
    ("LoraLoaderModelOnly", "lora_name", "lightx2v"),
    ("LoadVideo", "file", "context.mkv"),
    # Shipped with the image, not staged. Listed here because the placeholders
    # were originally mounted over input/, which deleted it -- and the only
    # symptom was a workflow rejected for naming a file that had been there.
    ("LoadImage", "image", "example.png"),
):
    got = choices(node, field)
    if not any(want in str(c) for c in got):
        sys.exit(
            f"FAIL: {node}.{field} does not list a {want} file; the "
            f"placeholders did not reach the enumeration. Saw: {got}"
        )

print(f"ok: {len(info)} node classes, all {len(required)} required present, "
      "model enumerations populated")
PY

echo "wrote $OUT ($(wc -c < "$OUT") bytes)"

# ------------------------------------------------------------------------
# Second use of the same container: put every workflow in workflows/ through
# ComfyUI's own validator.
#
# There is no dry-run route. POST /prompt runs execution.validate_prompt and
# only queues on success, so the response code is the verdict: 400 carries
# node_errors naming the offending node and input, 200 means the graph is one
# this build will accept. A 200 leaves a job queued against zero-byte weights,
# which is why the run is interrupted immediately and the container discarded.
#
# This is the check worth having. It is the same code path that would reject a
# graph on a rented GPU, running here for nothing.
# ------------------------------------------------------------------------
WORKFLOW_DIR="${WORKFLOW_DIR:-$(dirname "$0")/../workflows}"
if [ -d "$WORKFLOW_DIR" ]; then
  failed=0
  checked=0
  for wf in "$WORKFLOW_DIR"/*.json; do
    [ -e "$wf" ] || continue
    checked=$((checked + 1))
    body="$(mktemp)"
    python3 -c 'import json,sys; print(json.dumps({"prompt": json.load(open(sys.argv[1]))}))' \
        "$wf" > "$body"
    code=$(curl -s -o /tmp/validate-reply.json -w '%{http_code}' \
           --max-time 60 -X POST -H 'Content-Type: application/json' \
           --data-binary "@$body" "http://127.0.0.1:${PORT}/prompt" || echo 000)
    rm -f "$body"
    if [ "$code" = "200" ]; then
      echo "ok: $(basename "$wf") accepted by validate_prompt"
      curl -s -X POST "http://127.0.0.1:${PORT}/interrupt" >/dev/null || true
    else
      echo "FAIL: $(basename "$wf") rejected (HTTP $code)" >&2
      # Print the reply verbatim. An earlier version formatted it with inline
      # python and the nested quoting was a syntax error, so the one thing this
      # branch exists to say -- why the graph was rejected -- was the one thing
      # it could not say. Formatting is not worth a second failure mode.
      python3 -m json.tool < /tmp/validate-reply.json >&2 2>/dev/null \
        || cat /tmp/validate-reply.json >&2
      echo >&2
      failed=$((failed + 1))
    fi
  done
  if [ "$checked" -eq 0 ]; then
    echo "FAIL: $WORKFLOW_DIR contains no workflows to validate" >&2
    exit 1
  fi
  echo "validated $checked workflow(s), $failed rejected"
  [ "$failed" -eq 0 ] || exit 1
fi
