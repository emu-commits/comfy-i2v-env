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
  rm -rf "${STUBS:-}" 2>/dev/null || true
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

echo "starting $IMAGE on CPU..."
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:${PORT}" \
  -v "$STUBS:/opt/ComfyUI/models:ro" "$IMAGE" \
  python main.py --cpu --listen 0.0.0.0 --port "$PORT" \
                 --disable-auto-launch --disable-metadata >/dev/null

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
):
    got = choices(node, field)
    if not any(want in str(c) for c in got):
        sys.exit(
            f"FAIL: {node}.{field} does not list a {want} file; the model "
            f"placeholders did not reach the enumeration. Saw: {got}"
        )

print(f"ok: {len(info)} node classes, all {len(required)} required present, "
      "model enumerations populated")
PY

echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
