#!/bin/bash
# Verifies that a built `srt` binary actually sandboxes, before it is published.
#
#   scripts/smoke-test-srt.sh ./srt-0.0.71-jb.1-darwin-arm64
#
# The settings files below use the exact shape JetBrains Junie generates, so a schema change that
# would break Junie fails here instead of in a packaged build.
set -euo pipefail

SRT="${1:?usage: smoke-test-srt.sh <path to srt binary>}"
[ -x "$SRT" ] || { echo "FAIL: $SRT is not executable"; exit 1; }

# Under $HOME, not TMPDIR: srt grants itself a private TMPDIR, so a work directory there would pass
# the allowWrite assertions even if allowWrite were ignored entirely.
WORK="${HOME}/.srt-smoke-$$"
DENIED="${HOME}/.srt-smoke-denied-$$"
SETTINGS="${WORK}/settings.json"
BAD_SETTINGS="${WORK}/settings-missing-domains.json"

cleanup() { rm -rf "$WORK" "$DENIED"; }
trap cleanup EXIT

mkdir -p "$WORK" "$DENIED"

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; exit 1; }

# --- 1. the binary starts and reports a version ---------------------------------------------
version="$("$SRT" --version)" || fail "--version exited non-zero"
[ -n "$version" ] || fail "--version printed nothing"
pass "--version prints ${version}"

# --- 2. a policy Junie would generate ------------------------------------------------------
cat > "$SETTINGS" <<EOF
{
  "network": {
    "unrestricted": true,
    "allowedDomains": [],
    "deniedDomains": [],
    "allowUnixSockets": [],
    "allowLocalBinding": true
  },
  "filesystem": {
    "allowWrite": ["${WORK}"],
    "denyWrite": [],
    "denyRead": [],
    "allowRead": []
  },
  "ignoreViolations": {},
  "enableWeakerNetworkIsolation": false
}
EOF

if "$SRT" --settings "$SETTINGS" bash -c "touch '${WORK}/granted'"; then
  [ -f "${WORK}/granted" ] || fail "a write inside allowWrite reported success but created nothing"
  pass "write inside allowWrite succeeds"
else
  fail "a write inside allowWrite was denied"
fi

# The load-bearing assertion: a sandbox that silently does not sandbox is worse than none.
if "$SRT" --settings "$SETTINGS" bash -c "touch '${DENIED}/escaped'" 2>/dev/null; then
  fail "a write outside allowWrite succeeded — the filesystem jail is NOT active"
fi
[ ! -f "${DENIED}/escaped" ] || fail "a write outside allowWrite created the file anyway"
pass "write outside allowWrite is denied"

# --- 3. unrestricted network really lets traffic out ---------------------------------------
http_code="$("$SRT" --settings "$SETTINGS" bash -c \
  "curl -sS -o /dev/null -w '%{http_code}' https://example.com" 2>/dev/null || true)"
[ "$http_code" = "200" ] || fail "curl under network.unrestricted returned '${http_code}', expected 200"
pass "network.unrestricted allows egress"

# --- 4. the allowlist keys stay required --------------------------------------------------
# Junie's SrtSettingsWriter always emits allowedDomains/deniedDomains because srt requires them even
# when unrestricted. If upstream ever relaxes that, we want to know from this failure and not from a
# silently different network posture.
cat > "$BAD_SETTINGS" <<EOF
{
  "network": { "unrestricted": true },
  "filesystem": { "allowWrite": ["${WORK}"], "denyRead": [] }
}
EOF

if "$SRT" --settings "$BAD_SETTINGS" true 2>/dev/null; then
  fail "settings without allowedDomains/deniedDomains were accepted — the schema changed"
fi
pass "settings without allowedDomains/deniedDomains are rejected"

echo "All smoke tests passed for ${SRT}"
