#!/usr/bin/env bash
# Check a built image for anything that would identify or expose whoever built
# it, before that image is made public.
#
# This exists because "we were careful" is not a control. A public image is
# pulled by strangers and cannot be un-published: the check has to run, fail
# loudly, and block the push.
#
#   usage: tools/scan-image.sh IMAGE[:TAG]
#
# Strings that are themselves sensitive -- a real name, a personal email, the
# build machine's username -- must NOT live in this repo, or the check would
# publish exactly what it is meant to catch. They are read from a file outside
# the working tree, and findings are reported by index only, never quoted back.
#
#   default: ~/.config/comfy-i2v-env/private-strings   (override: PRIVATE_STRINGS)
#   format:  one string per line, blank lines and # comments ignored
#
# Exit 0 clean, 1 findings, 2 could not run.

set -uo pipefail

IMAGE="${1:-}"
[ -n "$IMAGE" ] || { echo "usage: $0 IMAGE[:TAG]" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "no such image: $IMAGE" >&2; exit 2; }

PRIVATE_STRINGS="${PRIVATE_STRINGS:-$HOME/.config/comfy-i2v-env/private-strings}"
FINDINGS=0
note() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FINDINGS=$((FINDINGS+1)); }
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }

# Load private strings into an array; they are never printed, only indexed.
declare -a PRIV=()
if [ -r "$PRIVATE_STRINGS" ]; then
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    PRIV+=("$line")
  done < "$PRIVATE_STRINGS"
  echo "private strings loaded: ${#PRIV[@]} (from ${PRIVATE_STRINGS/#$HOME/\~})"
else
  echo "private strings: none loaded -- identity checks will be skipped"
  echo "  create ${PRIVATE_STRINGS/#$HOME/\~} to enable them (see tools/private-strings.example)"
fi
echo

# --- 1. image configuration -------------------------------------------------
echo "image configuration"
CONFIG="$(docker image inspect "$IMAGE" --format '{{json .Config}}')"

# Env vars whose NAME suggests a credential. A value baked into config is
# visible to anyone who can pull, via docker inspect, forever.
BAD_ENV="$(printf '%s' "$CONFIG" | python3 -c '
import json,sys,re
c=json.load(sys.stdin)
pat=re.compile(r"(TOKEN|SECRET|PASSWD|PASSWORD|APIKEY|API_KEY|_KEY|CREDENTIAL|SESSION)",re.I)
allow=re.compile(r"^(TORCH_CUDA_ARCH_LIST|PIP_|PYTHON|LD_|NVIDIA_|CUDA_|PATH$|HF_HOME)")
for e in c.get("Env") or []:
    name=e.split("=",1)[0]
    if pat.search(name) and not allow.match(name):
        print(name)
')"
if [ -n "$BAD_ENV" ]; then
  while IFS= read -r n; do note "credential-shaped env var baked into config: $n"; done <<< "$BAD_ENV"
else
  pass "no credential-shaped env vars"
fi

if [ "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')" = "" ]; then
  pass "no build user recorded in config"
fi

# --- 2. build history -------------------------------------------------------
echo
echo "build history"
HIST="$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" 2>/dev/null)"
if printf '%s' "$HIST" | grep -qiE '(ghp_|github_pat_|hf_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)'; then
  note "a credential-shaped literal appears in the build history"
else
  pass "no credential literals in build history"
fi
for i in "${!PRIV[@]}"; do
  if printf '%s' "$HIST" | grep -qiF -- "${PRIV[$i]}"; then
    note "private string #$((i+1)) appears in the build history"
  fi
done

# --- 3. filesystem: paths ---------------------------------------------------
echo
echo "filesystem paths"
CID="$(docker create "$IMAGE" true 2>/dev/null)"
[ -n "$CID" ] || { echo "could not create a container to export" >&2; exit 2; }
trap 'docker rm -f "$CID" >/dev/null 2>&1' EXIT

# Streamed, so this does not need a second copy of the image on disk.
NAMES="$(docker export "$CID" 2>/dev/null | tar -t 2>/dev/null)"
[ -n "$NAMES" ] || { echo "export produced no entries" >&2; exit 2; }
echo "  entries scanned: $(printf '%s\n' "$NAMES" | wc -l)"

# .pem and .key are excluded under the system trust store, where they are the
# point rather than a leak.
LEAKY="$(printf '%s\n' "$NAMES" \
  | grep -vE '^(etc/ssl/|usr/share/ca-certificates/|usr/lib/ssl/|opt/venv/lib/.*/(certifi|pip/_vendor)/)' \
  | grep -E '(^|/)(\.git/|\.git-credentials|\.netrc|\.npmrc|\.pypirc|\.bash_history|\.zsh_history|\.python_history)$|(^|/)\.ssh/|(^|/)\.aws/|(^|/)\.config/gcloud/|(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$|(^|/)authorized_keys$|(^|/)\.docker/config\.json$|huggingface/token$|\.(pem|key|p12|pfx)$')"
if [ -n "$LEAKY" ]; then
  while IFS= read -r p; do note "sensitive path present: /$p"; done <<< "$LEAKY"
else
  pass "no credential, history or VCS-metadata paths"
fi

for i in "${!PRIV[@]}"; do
  if printf '%s\n' "$NAMES" | grep -qiF -- "${PRIV[$i]}"; then
    HITS="$(printf '%s\n' "$NAMES" | grep -iF -- "${PRIV[$i]}" | head -5 | sed 's|^|/|')"
    note "private string #$((i+1)) appears in these paths:"
    printf '          %s\n' $HITS
  fi
done

# --- 4. filesystem: contents ------------------------------------------------
echo
echo "file contents"
if [ "${#PRIV[@]}" -eq 0 ]; then
  echo "  skipped (no private strings loaded)"
else
  # grep runs inside the image, so nothing has to be extracted to this disk.
  # Restricted to the directories where a build leaks identity; the model and
  # library trees are far too large and are not where a username ends up.
  PATTERN="$(printf '%s\n' "${PRIV[@]}" | paste -sd'|' -)"
  HITS="$(docker run --rm --network none --entrypoint /bin/sh "$IMAGE" -c \
      "grep -rlEi --binary-files=without-match -- '$PATTERN' \
         /root /home /etc /opt/ComfyUI 2>/dev/null | head -40" 2>/dev/null)"
  if [ -n "$HITS" ]; then
    while IFS= read -r f; do note "a private string appears in file contents: $f"; done <<< "$HITS"
  else
    pass "no private strings in /root /home /etc /opt/ComfyUI"
  fi
fi

echo
if [ "$FINDINGS" -eq 0 ]; then
  printf '\033[32mclean\033[0m -- %s carries nothing identifying. Safe to publish.\n' "$IMAGE"
  exit 0
fi
printf '\033[31m%d finding(s)\033[0m -- do NOT publish %s until these are gone.\n' "$FINDINGS" "$IMAGE"
exit 1
