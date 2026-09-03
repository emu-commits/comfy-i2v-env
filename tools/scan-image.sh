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

# Every call below that needs a container to START is bounded. A wedged Docker
# does not refuse -- it blocks, and a plain $(...) waits on the pipe even after
# timeout has killed the client, so the gate hangs instead of reporting. -k
# follows up with SIGKILL, and the output goes to a file rather than a pipe.
SCAN_TIMEOUT="${SCAN_TIMEOUT:-120}"
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
docker_bounded() {   # docker_bounded <seconds> <args...>; stdout lands in $OUT
  local secs="$1"; shift
  # Run under an inner shell whose stderr we control. A signalled foreground
  # child is announced by the shell that reaped it, on *its own* stderr, so a
  # subshell redirect does not catch it -- and a bare "Killed" line in the
  # middle of a security report reads like the tool crashed rather than like
  # the timeout doing its job.
  SCAN_OUT="$OUT" bash -c 'timeout -k 5 "$1" docker "${@:2}" >"$SCAN_OUT" 2>/dev/null' \
      _ "$secs" "$@" 2>/dev/null
}

# Whether the check RAN is a separate question from what it found, and grep's
# exit status cannot answer it: grep returns 2 both when it could not start and
# when it merely met an unreadable file, which a trust store full of dangling
# symlinks guarantees. So the snippet prints a sentinel as its last act, and the
# presence of that line -- not an exit code -- is what proves the check happened.
SENTINEL="__SCAN_COMPLETED__"
run_in_image() {   # run_in_image <seconds> <sh-snippet>; findings land in $OUT
  docker_bounded "$1" run --rm --network none --entrypoint /bin/sh "$IMAGE" \
      -c "$2; echo $SENTINEL"
  if grep -qx "$SENTINEL" "$OUT" 2>/dev/null; then
    sed -i "/^${SENTINEL}\$/d" "$OUT"
    return 0
  fi
  return 1
}

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
docker_bounded 60 create "$IMAGE" true; CID="$(cat "$OUT")"
[ -n "$CID" ] || { echo "could not create a container to export" >&2; exit 2; }
trap 'docker rm -f "$CID" >/dev/null 2>&1; rm -f "$OUT"' EXIT

# Streamed, so this does not need a second copy of the image on disk.
NAMES="$(timeout -k 5 300 docker export "$CID" 2>/dev/null | tar -t 2>/dev/null)"
[ -n "$NAMES" ] || { echo "export produced no entries" >&2; exit 2; }
echo "  entries scanned: $(printf '%s\n' "$NAMES" | wc -l)"

LEAKY="$(printf '%s\n' "$NAMES" \
  | grep -E '(^|/)(\.git/|\.git-credentials|\.netrc|\.npmrc|\.pypirc|\.bash_history|\.zsh_history|\.python_history)$|(^|/)\.ssh/|(^|/)\.aws/|(^|/)\.config/gcloud/|(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$|(^|/)authorized_keys$|(^|/)\.docker/config\.json$|huggingface/token$|\.(p12|pfx)$')"
if [ -n "$LEAKY" ]; then
  while IFS= read -r f; do note "sensitive path present: /$f"; done <<< "$LEAKY"
else
  pass "no credential, history or VCS-metadata paths"
fi

# .pem and .key are judged by CONTENT, not by extension. Every base image ships
# public certificates with those suffixes -- trust stores, GnuPG keyring CAs,
# certifi -- and an extension rule flags all of them while catching nothing that
# a real leak would not also trip. What actually matters is a private key
# header, so look for one.
CANDIDATES="$(printf '%s\n' "$NAMES" | grep -E '\.(pem|key)$' || true)"
if [ -z "$CANDIDATES" ]; then
  pass "no .pem/.key files at all"
else
  N=$(printf '%s\n' "$CANDIDATES" | wc -l)
  FILES="$(printf '%s\n' "$CANDIDATES" | sed 's|^|/|' | tr '\n' ' ')"
  # -f skips the dangling symlinks a trust store is full of: they are not files,
  # and their absence says nothing about whether the image carries a key.
  if run_in_image "$SCAN_TIMEOUT" \
      "for f in $FILES; do [ -f \"\$f\" ] || continue; grep -lE -- '-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----' \"\$f\" 2>/dev/null; done"; then
    PRIVKEYS="$(cat "$OUT")"
    if [ -n "$PRIVKEYS" ]; then
      while IFS= read -r f; do note "PRIVATE KEY material in image: $f"; done <<< "$PRIVKEYS"
    else
      pass "$N .pem/.key files present, none contain private key material"
    fi
  else
    note "could not inspect $N .pem/.key files -- INCONCLUSIVE, not clean"
  fi
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
  if run_in_image "$SCAN_TIMEOUT" \
      "grep -rlEi --binary-files=without-match -- '$PATTERN' /root /home /etc /opt/ComfyUI 2>/dev/null | head -40"; then
    HITS="$(cat "$OUT")"
    if [ -n "$HITS" ]; then
      while IFS= read -r f; do note "a private string appears in file contents: $f"; done <<< "$HITS"
    else
      pass "no private strings in /root /home /etc /opt/ComfyUI"
    fi
  else
    note "content scan could not run -- INCONCLUSIVE, not clean"
  fi
fi

echo
if [ "$FINDINGS" -eq 0 ]; then
  printf '\033[32mclean\033[0m -- %s carries nothing identifying. Safe to publish.\n' "$IMAGE"
  exit 0
fi
printf '\033[31m%d finding(s)\033[0m -- do NOT publish %s until these are gone.\n' "$FINDINGS" "$IMAGE"
exit 1
