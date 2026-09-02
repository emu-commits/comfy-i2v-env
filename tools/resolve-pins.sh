#!/usr/bin/env bash
# Re-resolve every pin in pins.env against upstream and print the new file.
# Review the diff before committing: this is the moment a supply chain changes.
#
#   usage: tools/resolve-pins.sh > pins.env.new && diff -u pins.env pins.env.new
#
# GITHUB_TOKEN is optional; without it the GitHub API rate limit is low enough
# that this may fail rather than lie.
set -euo pipefail

gh_api() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sSfL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$1"
  else
    curl -sSfL -H "Accept: application/vnd.github+json" "$1"
  fi
}

digest_of() {
  docker manifest inspect -v "$1" | python3 -c '
import json,sys
d=json.load(sys.stdin)
entries = d if isinstance(d, list) else [d]
for e in entries:
    p = e.get("Descriptor",{}).get("platform",{})
    if p.get("architecture") == "amd64" and p.get("os") == "linux":
        print(e["Descriptor"]["digest"]); break
else:
    sys.exit("no linux/amd64 manifest for " + sys.argv[0])
'
}

CUDA_TAG="${CUDA_TAG:-12.9.1}"
DEVEL="$(digest_of "nvidia/cuda:${CUDA_TAG}-cudnn-devel-ubuntu24.04")"
RUNTIME="$(digest_of "nvidia/cuda:${CUDA_TAG}-cudnn-runtime-ubuntu24.04")"

# ComfyUI moved namespace once already, so resolve by repository id rather than
# by owner/name: the id survives a rename, the path does not.
COMFY_ID=589831718
COMFY_FULL="$(gh_api "https://api.github.com/repositories/${COMFY_ID}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["full_name"])')"
COMFY_TAG="$(gh_api "https://api.github.com/repos/${COMFY_FULL}/releases/latest" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
COMFY_SHA="$(gh_api "https://api.github.com/repos/${COMFY_FULL}/commits/${COMFY_TAG}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha"])')"

cat <<EOF
# Immutable pins. Regenerate with tools/resolve-pins.sh, review the diff, commit.
# Every value here is a digest or a commit SHA: no tags that can move underneath us.
# Resolved $(date -u +%Y-%m-%d).

BASE_DEVEL=nvidia/cuda@${DEVEL}
BASE_RUNTIME=nvidia/cuda@${RUNTIME}

TORCH_CHANNEL=${TORCH_CHANNEL:-cu129}
TORCH_VERSION=${TORCH_VERSION:-2.13.0}

COMFYUI_REPO=https://github.com/${COMFY_FULL}
COMFYUI_SHA=${COMFY_SHA}
COMFYUI_RELEASE=${COMFY_TAG}
EOF
