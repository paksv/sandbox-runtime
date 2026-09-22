#!/bin/bash
# Verifies that a built `srt` binary actually sandboxes, before it is published.
#
#   scripts/smoke-test-srt.sh ./srt-0.0.71-jb.1-darwin-arm64
#
# The settings files below use the exact shape JetBrains Junie generates, so a schema change that
# would break Junie fails here instead of in a packaged build.
set -euo pipefail

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }

SRT="${1:?usage: smoke-test-srt.sh <path to srt binary> [path to apply-seccomp]}"
[ -f "$SRT" ] && [ -x "$SRT" ] || fail "$SRT is not an executable file"
SOURCE_SRT="$(cd "$(dirname "$SRT")" && pwd -P)/$(basename "$SRT")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FIXTURE="${SCRIPT_DIR}/smoke-test-srt-fixture.py"
PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Linux) dependencies=(python3 curl bash bwrap socat rg) ;;
  Darwin) dependencies=(python3 curl bash sandbox-exec) ;;
  *) fail "unsupported platform: $PLATFORM" ;;
esac
for dependency in "${dependencies[@]}"; do
  command -v "$dependency" >/dev/null || fail "required system tool missing: $dependency"
done
PYTHON="$(command -v python3)"
if [ "$PLATFORM" = Linux ]; then
  HELPER="${2:-$(dirname "$SOURCE_SRT")/apply-seccomp}"
  [ -f "$HELPER" ] && [ -x "$HELPER" ] || fail "$HELPER is not an executable helper; supply it as the second argument"
  SOURCE_HELPER="$(cd "$(dirname "$HELPER")" && pwd -P)/$(basename "$HELPER")"
fi

# Under $HOME, not TMPDIR: srt grants itself a private TMPDIR, so a work directory there would pass
# the allowWrite assertions even if allowWrite were ignored entirely.
WORK="$(mktemp -d "${HOME}/.srt-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
PROJECT="${WORK}/project"
SETTINGS="${WORK}/settings.json"
BAD_SETTINGS="${WORK}/settings-missing-domains.json"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$PROJECT" "${WORK}/native assets"
cp "$SOURCE_SRT" "${WORK}/native assets/srt"
SRT="${WORK}/native assets/srt"
if [ "$PLATFORM" = Linux ]; then
  cp "$SOURCE_HELPER" "${WORK}/native assets/apply-seccomp"
fi
cd "$PROJECT"

fixture() { "$PYTHON" -I "$FIXTURE" "$@"; }
policy() { fixture policy "$WORK" "$@" > "$SETTINGS"; }
probe() {
  local completion="${PROJECT}/probe-completed"
  rm -f "$completion"
  "$SRT" --settings "$SETTINGS" "$PYTHON" -I "$FIXTURE" probe "$completion" "$@" || fail "sandbox probe failed: $*"
  [ -f "$completion" ] || fail "sandbox probe returned success without completing: $*"
}

export NO_PROXY="127.0.0.1,localhost,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
"$PYTHON" -I "$FIXTURE" serve "${WORK}/endpoints.json" > "${WORK}/server.log" 2>&1 &
SERVER_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [ ! -f "${WORK}/endpoints.json" ] || break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "${WORK}/server.log" >&2
    fail "local fixture server exited before readiness"
  fi
  sleep 0.1
done
[ -f "${WORK}/endpoints.json" ] || fail "local fixture server did not become ready"
fixture network "${WORK}/endpoints.json" direct
fixture unix true "$PROJECT"
pass "local HTTP, non-HTTP TCP, and Unix socket controls succeed outside the sandbox"

# --- 1. the binary starts and reports a version ---------------------------------------------
version="$("$SRT" --version)" || fail "--version exited non-zero"
[ -n "$version" ] || fail "--version printed nothing"
pass "--version prints ${version}"

# --- 2. a policy Junie would generate ------------------------------------------------------
socket_modes=(false)
[ "$PLATFORM" != Linux ] || socket_modes=(true false)
for unrestricted in true false; do
  for allow_unix in "${socket_modes[@]}"; do
    fixture prepare "$WORK"
    if [ "$unrestricted" = true ]; then
      policy true "$allow_unix" empty
    else
      policy false "$allow_unix" allowed
    fi
    probe filesystem "$WORK"
    fixture unchanged "$WORK"
    pass "filesystem allowWrite and protected create/overwrite/delete/rename: unrestricted=$unrestricted, allowAllUnixSockets=$allow_unix"
    if [ "$PLATFORM" = Linux ]; then
      probe unix "$allow_unix" "$PROJECT"
      pass "Unix socket policy: unrestricted=$unrestricted, allowAllUnixSockets=$allow_unix"
    fi
    if [ "$unrestricted" = true ]; then
      probe network "${WORK}/endpoints.json" direct
      pass "unrestricted local HTTP and non-HTTP TCP traffic: allowAllUnixSockets=$allow_unix"
    else
      probe network "${WORK}/endpoints.json" filtered
      for domains in empty precedence; do
        policy false "$allow_unix" "$domains"
        probe network "${WORK}/endpoints.json" blocked
        pass "filtered network $domains: allowAllUnixSockets=$allow_unix"
      done
      fixture network "${WORK}/endpoints.json" direct
      pass "filtered allowed/denied hosts and direct TCP isolation: allowAllUnixSockets=$allow_unix"
    fi
  done
done

# --- 3. unrestricted network really lets traffic out ---------------------------------------
if [ "$PLATFORM" = Darwin ]; then
  policy true false empty
  http_code="$("$SRT" --settings "$SETTINGS" -- curl --connect-timeout 10 --max-time 30 \
    -sS -o /dev/null -w '%{http_code}' https://example.com)" || fail "unrestricted curl failed"
  [ "$http_code" = "200" ] || fail "curl under network.unrestricted returned '${http_code}', expected 200"
  pass "network.unrestricted allows egress"
fi

# --- 4. the allowlist keys stay required --------------------------------------------------
# Junie's SrtSettingsWriter always emits allowedDomains/deniedDomains because srt requires them even
# when unrestricted. If upstream ever relaxes that, we want to know from this failure and not from a
# silently different network posture.
fixture bad-policy "$WORK" > "$BAD_SETTINGS"
status=0
"$SRT" --settings "$BAD_SETTINGS" touch "${PROJECT}/schema-marker" > "${WORK}/rejection.log" 2>&1 || status=$?
fixture rejection schema "$status" "${WORK}/rejection.log" "${PROJECT}/schema-marker"
pass "settings without allowedDomains/deniedDomains are rejected"

if [ "$PLATFORM" = Linux ]; then
  for helper_state in missing nonexecutable; do
    if [ "$helper_state" = missing ]; then
      mv "${WORK}/native assets/apply-seccomp" "${WORK}/saved-helper"
    else
      mv "${WORK}/saved-helper" "${WORK}/native assets/apply-seccomp"
      chmod a-x "${WORK}/native assets/apply-seccomp"
    fi
    for unrestricted in true false; do
      policy "$unrestricted" false allowed
      marker="${PROJECT}/${helper_state}-${unrestricted}-marker"
      status=0
      "$SRT" --settings "$SETTINGS" touch "$marker" > "${WORK}/rejection.log" 2>&1 || status=$?
      fixture rejection "$helper_state" "$status" "${WORK}/rejection.log" "$marker"
      pass "$helper_state helper fails visibly without executing the command: unrestricted=$unrestricted"
      policy "$unrestricted" true allowed
      probe unix true "$PROJECT"
      pass "allowAllUnixSockets succeeds with $helper_state helper: unrestricted=$unrestricted"
    done
  done
fi

echo "All smoke tests passed for ${SOURCE_SRT} (relocated to a path with spaces)"
