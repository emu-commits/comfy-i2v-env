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
  docker logs "$NAME" > /tmp/${NAME}.log 2>&1 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "starting $IMAGE on CPU..."
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:${PORT}" "$IMAGE" \
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
print(f"ok: {len(info)} node classes, all {len(required)} required ones present")
PY

echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
