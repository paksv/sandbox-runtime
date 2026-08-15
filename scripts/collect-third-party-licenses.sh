#!/bin/bash
# Assembles THIRD-PARTY from the licenses of the runtime dependencies `bun build --compile` inlines
# into the binary. MIT's "all copies or substantial portions" clause has no escape hatch, so this
# file must ship next to the binary.
#
#   npm ci && scripts/collect-third-party-licenses.sh
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT="THIRD-PARTY"
PACKAGES="commander zod @pondwader/socks5-server node-forge"

read_field() {
  node -e "process.stdout.write(String(require('./node_modules/$1/package.json').$2 ?? ''))"
}

{
  echo "Third-party components statically included in the srt binary."
  echo
  echo "The binary is produced with 'bun build --compile', which inlines the whole reachable module"
  echo "graph. The licenses of those modules are reproduced verbatim below."
} > "$OUTPUT"

for pkg in $PACKAGES; do
  dir="node_modules/${pkg}"
  [ -d "$dir" ] || { echo "Error: ${dir} is missing; run 'npm ci' first" >&2; exit 1; }

  license_file=""
  for candidate in LICENSE LICENSE.md LICENSE.txt LICENCE license; do
    if [ -f "${dir}/${candidate}" ]; then
      license_file="${dir}/${candidate}"
      break
    fi
  done
  [ -n "$license_file" ] || { echo "Error: no license file found in ${dir}" >&2; exit 1; }

  version="$(read_field "$pkg" version)"
  spdx="$(read_field "$pkg" license)"
  [ -n "$version" ] || { echo "Error: no version in ${dir}/package.json" >&2; exit 1; }

  {
    echo
    echo "================================================================================"
    printf '%s %s — %s\n' "$pkg" "$version" "${spdx:-see license text below}"
    if [ "$pkg" = "node-forge" ]; then
      echo "Dual-licensed; JetBrains elects BSD-3-Clause."
    fi
    echo "================================================================================"
    echo
    cat "$license_file"
  } >> "$OUTPUT"
done

echo "Wrote ${OUTPUT} for: ${PACKAGES}"
