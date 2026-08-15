# JetBrains builds of srt

This fork exists to ship `srt` inside the JetBrains Junie CLI instead of asking users to
`npm install -g @anthropic-ai/sandbox-runtime`. `.github/workflows/release-junie.yml` compiles
`src/cli.ts` into two standalone macOS executables with `bun build --compile`, smoke-tests them, and
publishes them as GitHub Release assets. Junie's macOS packaging then downloads, verifies, stages and
signs them.

Nothing here changes upstream behaviour. The only functional delta of this fork over
`anthropic-experimental/sandbox-runtime` is the `network.unrestricted` / `--unrestricted-network`
option (commit `c857ae7`), documented in `MODIFICATIONS`.

---

## Why a separate workflow

`release.yml` is upstream's: its `publish` job runs `npm publish` for `@anthropic-ai/sandbox-runtime`
with upstream's `NPM_TOKEN` and `--provenance`, and it gates on the release tag living on upstream
`main`. Editing it would be both wrong (we must not publish to their npm name) and painful (a conflict
on every rebase onto upstream).

The same reasoning applies to everything else here: `release.yml` and `integration-tests.yml` must stay
**byte-identical to upstream**, and `package.json` `version` is never bumped. Keep the fork's delta at
`c857ae7` plus the JetBrains-only files listed at the bottom, and rebasing stays mechanical.

---

## Versioning

The version of record is the `JB_VERSION` file: `<upstream version>-jb.<n>`, currently `0.0.71-jb.1`.

- Bump `<n>` when you rebuild the same upstream version (a workflow fix, a new dependency lockfile).
- Bump the upstream part after a rebase onto a new upstream release, and reset `<n>` to 1.
- `package.json` stays untouched, which is why `srt --version` still prints upstream's `1.0.0`. Identify
  a build by its asset name and sha256, not by `--version`.

---

## Cutting a release

```bash
# 1. optional: rebase onto a new upstream release first
# 2. bump the version of record
echo "0.0.71-jb.2" > JB_VERSION
git commit -am "chore: JB_VERSION 0.0.71-jb.2"

# 3. tag and push — the tag is the trigger
git tag jb-v0.0.71-jb.2
git push origin main --tags
```

The workflow refuses to publish if the tag does not equal `jb-v$(cat JB_VERSION)`, if `npm run build`
(`tsc`) or `npm test` fail, or if either architecture's smoke test fails. The `test` job installs
`ripgrep` and `zsh` with Homebrew first, the same system dependencies `integration-tests.yml` installs
on its macOS lane.

**Dry run:** trigger `Release (JetBrains)` manually (`workflow_dispatch`). It runs the tests, builds both
architectures and smoke-tests them, and skips the `publish` job entirely.

---

## Published assets

For `JB_VERSION=0.0.71-jb.1`, tag `jb-v0.0.71-jb.1`:

```
srt-0.0.71-jb.1-darwin-arm64
srt-0.0.71-jb.1-darwin-arm64.sha256
srt-0.0.71-jb.1-darwin-x64
srt-0.0.71-jb.1-darwin-x64.sha256
LICENSE
MODIFICATIONS
THIRD-PARTY
```

Download URL template:

```
https://github.com/paksv/sandbox-runtime/releases/download/jb-v<version>/srt-<version>-darwin-<arch>
```

`<arch>` is `arm64` or `x64`.

**The `.sha256` format is a contract with Junie's packaging script**: it is the plain output of
`shasum -a 256 <asset-name>` — the digest, two spaces, and the asset file name — so a consumer that
downloads the asset under its published name can verify it with `shasum -a 256 -c <asset>.sha256`. Do
not switch to a bare digest or a different file name.

**The binaries are unsigned by design.** Junie signs and notarizes them as part of its own `junie.app`,
with the `com.apple.security.cs.allow-jit` entitlement bun's JavaScriptCore needs under the hardened
runtime. Signing here would only be thrown away.

---

## Runners

| Architecture | Runner label | Note |
|---|---|---|
| arm64 | `macos-14` | |
| x86-64 | `macos-15-intel` | `macos-13` was retired on 2025-12-04. This is the **last** Intel image GitHub Actions offers, available until **August 2027** — after that the x64 asset needs a different build host (a self-hosted Intel Mac, or cross-compiling and giving up the native smoke test). |

Each architecture is built on its own native host on purpose. `bun build --compile --target=...` can
cross-compile, but a cross-compiled binary cannot be executed on the build host, so it could not be
smoke-tested — and an unverified sandbox binary is exactly what must never be published.

`bun` is pinned to `1.3.14`, matching `integration-tests.yml`. (`release.yml` still pins `1.3.1` for its
seccomp job; leave it alone.)

---

## Building and testing locally

```bash
npm ci
bun build --compile --target=bun-darwin-arm64 src/cli.ts --outfile srt-local
scripts/smoke-test-srt.sh ./srt-local
```

Replace the target with `bun-darwin-x64` to cross-compile the Intel binary — but note you cannot run
the smoke test against it on an Apple Silicon host without Rosetta, and CI is the only place both
architectures are natively verified.

Junie's side has a helper that does the same thing and exports the result:
`scripts/fetch-srt.sh --from-source /path/to/this/checkout` in the Junie repo.

Measured, so you do not have to: the arm64 output is ~58-60 MB (~22 MB gzipped), bundles 96 modules and
compiles in well under a second. **Do not add `--minify --bytecode`** — the output gets *bigger*
(61.8 MB).

### What the smoke test asserts

`scripts/smoke-test-srt.sh` takes a path to a binary and checks, in order:

1. `--version` exits 0 and prints something.
2. A write **inside** `filesystem.allowWrite` succeeds.
3. A write **outside** it fails and creates nothing. This is the load-bearing one: a sandbox that
   silently does not sandbox is worse than no sandbox at all.
4. `curl https://example.com` returns 200 with `network.unrestricted: true`, proving the escape hatch
   really bypasses the proxy.
5. A settings file **without** `network.allowedDomains` / `network.deniedDomains` is rejected. Those keys
   are required by the zod schema even when `unrestricted` is set, and Junie's settings writer depends
   on that staying true; if upstream ever relaxes it, this failure is how we find out.

Its work directories live under `$HOME`, not `TMPDIR`, because `srt` grants itself a private `TMPDIR` —
a work directory there would pass assertion 2 even if `allowWrite` were ignored entirely.

The settings files it writes use the exact shape Junie's `SrtSettingsWriter` produces, so a schema drift
that would break Junie fails here instead of in a packaged build.

---

## Licensing artifacts

| File | Why |
|---|---|
| `LICENSE` | Upstream's verbatim Apache-2.0 (`Copyright 2025 Anthropic`). Apache-2.0 §4(a). |
| `MODIFICATIONS` | States that this is a modified copy, what was changed, and where the modified source lives. Apache-2.0 §4(b). Keeping this fork public is what makes it trivially defensible. |
| `THIRD-PARTY` | Generated by `scripts/collect-third-party-licenses.sh` from `node_modules`: the MIT/BSD texts of `commander`, `zod`, `@pondwader/socks5-server` and `node-forge`, which `bun build --compile` statically inlines into the binary. `node-forge` is dual BSD-3-Clause/GPL-2.0; JetBrains elects BSD-3-Clause. |

`THIRD-PARTY` is generated, not committed — the workflow rebuilds it in the `publish` job and uploads it
as a release asset. Upstream has no `NOTICE` file, so Apache-2.0 §4(d) does not apply.

Two things this does **not** cover, both tracked on the Junie side:

- Bun statically links **JavaScriptCore (LGPL-2.1)** into every `--compile` output. We modify neither bun
  nor WebKit, and both are public, but shipping that inside a signed, notarized, proprietary app needs
  legal sign-off.
- Apache-2.0 §6 grants no trademark rights: do not market Junie's sandbox as "Anthropic-powered", and do
  not ship this repo's `README.md` (titled "Anthropic Sandbox Runtime") inside the app. The compiled CLI
  itself is brand-neutral — `src/cli.ts` sets `.name('srt')` and prints no Anthropic/Claude strings in
  `--help` or `--version`.

---

## JetBrains-only files in this fork

Everything else is upstream's and should stay that way.

```
JB_VERSION
MODIFICATIONS
.github/workflows/release-junie.yml
scripts/smoke-test-srt.sh
scripts/collect-third-party-licenses.sh
docs/jetbrains-build.md
```
