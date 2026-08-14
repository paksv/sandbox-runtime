import { describe, it, expect, afterAll } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { SandboxManager } from '../../src/sandbox/sandbox-manager.js'
import type { SandboxRuntimeConfig } from '../../src/sandbox/sandbox-config.js'
import { isLinux, isMacOS } from '../helpers/platform.js'

/**
 * Tests for network.unrestricted.
 *
 * When true, no network policy is enforced: no proxy/bridge is started,
 * no proxy env vars reach the child, and the allowlist fields are
 * ignored (macOS emits `(allow network*)`; Linux skips --unshare-net).
 * Filesystem/credential-env restrictions are unaffected.
 *
 * Windows rejects the flag at initialize() — the WFP egress fence is
 * keyed on the sandbox SID, so skipping the proxy there means no
 * network at all.
 */
describe.if(isMacOS || isLinux)('network.unrestricted', () => {
  const TEST_DIR = join(tmpdir(), 'srt-net-unrestricted-' + Date.now())

  // Tests that spawn a real request need more than bun's 5s default.
  const NET_TIMEOUT_MS = 30000

  // allowWrite deliberately points elsewhere so TEST_DIR is covered by no
  // write rule: the flag must not loosen the filesystem layer.
  const baseConfig = (unrestricted: boolean): SandboxRuntimeConfig => ({
    network: { allowedDomains: [], deniedDomains: [], unrestricted },
    filesystem: {
      denyRead: [],
      allowWrite: ['/nonexistent-allow-write'],
      denyWrite: [],
    },
  })

  const run = (wrapped: string) =>
    spawnSync(wrapped, { shell: true, encoding: 'utf8', timeout: 20000 })

  afterAll(async () => {
    await SandboxManager.reset()
    if (existsSync(TEST_DIR)) {
      rmSync(TEST_DIR, { recursive: true, force: true })
    }
  })

  it('starts no proxy listener and resets cleanly', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(true))

    expect(SandboxManager.getProxyPort()).toBeUndefined()
    expect(SandboxManager.getSocksProxyPort()).toBeUndefined()

    await SandboxManager.reset()
    expect(SandboxManager.getProxyPort()).toBeUndefined()
  })

  it('starts a proxy listener when the flag is absent (control)', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(false))

    expect(SandboxManager.getProxyPort()).toBeDefined()
  })

  it(
    'reaches the network',
    async () => {
      await SandboxManager.reset()
      await SandboxManager.initialize(baseConfig(true))

      const wrapped = await SandboxManager.wrapWithSandbox(
        'curl -sS --max-time 10 http://example.com',
      )
      const result = run(wrapped)

      expect(result.status).toBe(0)
      expect(result.stdout).toContain('Example Domain')
    },
    NET_TIMEOUT_MS,
  )

  it(
    'is blocked with an empty allowlist and no flag (control)',
    async () => {
      await SandboxManager.reset()
      await SandboxManager.initialize(baseConfig(false))

      // The proxy accepts the connection and then refuses the request, so
      // curl needs its own deadline rather than failing at connect time.
      const wrapped = await SandboxManager.wrapWithSandbox(
        'curl -sS --max-time 3 http://example.com',
      )
      const result = run(wrapped)

      expect(result.status).not.toBe(0)
      expect(result.stdout ?? '').not.toContain('Example Domain')
    },
    NET_TIMEOUT_MS,
  )

  it(
    'resolves DNS and completes a TLS handshake',
    async () => {
      await SandboxManager.reset()
      await SandboxManager.initialize(baseConfig(true))

      // The seatbelt profile is (deny default) and allowlists no resolver
      // or trustd mach service — under restriction the HOST proxy resolved
      // names and verified chains. This asserts the child can do both.
      const wrapped = await SandboxManager.wrapWithSandbox(
        `node -e "require('dns').promises.lookup('example.com')` +
          `.then(()=>fetch('https://example.com'))` +
          `.then(r=>console.log('ok',r.status))"`,
      )
      const result = run(wrapped)

      expect(result.stderr ?? '').not.toContain('Operation not permitted')
      expect(result.status).toBe(0)
      expect(result.stdout).toContain('ok 200')
    },
    NET_TIMEOUT_MS,
  )

  it('leaks no proxy env vars into the child but keeps SANDBOX_RUNTIME', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(true))

    const wrapped = await SandboxManager.wrapWithSandbox(
      `printf 'http=[%s] https=[%s] no=[%s] ca=[%s] srt=[%s]' ` +
        `"$HTTP_PROXY" "$HTTPS_PROXY" "$NO_PROXY" ` +
        `"$NODE_EXTRA_CA_CERTS" "$SANDBOX_RUNTIME"`,
    )
    const result = run(wrapped)

    expect(result.status).toBe(0)
    expect(result.stdout).toBe('http=[] https=[] no=[] ca=[] srt=[1]')
  })

  it('still enforces the filesystem policy', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(true))

    mkdirSync(TEST_DIR, { recursive: true })
    const target = join(TEST_DIR, 'write.txt')
    const wrapped = await SandboxManager.wrapWithSandbox(
      `printf %s blocked > ${target}`,
    )
    const result = run(wrapped)

    expect(result.status).not.toBe(0)
    expect(existsSync(target)).toBe(false)
  })

  it(
    'per-call customConfig.network re-imposes restriction',
    async () => {
      await SandboxManager.reset()
      await SandboxManager.initialize(baseConfig(true))

      // The per-call block omits `unrestricted`, so it wins wholesale —
      // same precedence as customConfig.filesystem vs filesystem.disabled.
      const wrapped = await SandboxManager.wrapWithSandbox(
        'curl -sS --max-time 3 http://example.com',
        undefined,
        { network: { allowedDomains: [], deniedDomains: [] } },
      )
      const result = run(wrapped)

      expect(result.status).not.toBe(0)
      expect(result.stdout ?? '').not.toContain('Example Domain')
    },
    NET_TIMEOUT_MS,
  )

  it('drops the platform network restrictions from the generated command', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(true))
    const unrestricted = await SandboxManager.wrapWithSandbox('true')

    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(false))
    const restricted = await SandboxManager.wrapWithSandbox('true')

    if (isMacOS) {
      expect(unrestricted).toContain('(allow network*)')
      expect(unrestricted).not.toContain('(remote ip "localhost:')
      expect(restricted).not.toContain('(allow network*)')
    } else {
      expect(unrestricted).not.toContain('--unshare-net')
      expect(unrestricted).not.toContain('HTTP_PROXY')
      expect(restricted).toContain('--unshare-net')
    }
  })

  it('treats unrestricted: false like omitting the key', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(false))
    const explicitFalse = await SandboxManager.wrapWithSandbox('true')

    await SandboxManager.reset()
    await SandboxManager.initialize({
      ...baseConfig(false),
      network: { allowedDomains: [], deniedDomains: [] },
    })
    const omitted = await SandboxManager.wrapWithSandbox('true')

    if (isMacOS) {
      expect(explicitFalse).not.toContain('(allow network*)')
      expect(omitted).not.toContain('(allow network*)')
    } else {
      expect(explicitFalse).toContain('--unshare-net')
      expect(omitted).toContain('--unshare-net')
    }
  })

  it('rejects proxy-dependent options passed straight to initialize()', async () => {
    await SandboxManager.reset()

    // Library consumers pass an already-typed object that never goes
    // through the zod schema, so initialize() must guard too.
    const error = await SandboxManager.initialize({
      ...baseConfig(true),
      network: {
        allowedDomains: [],
        deniedDomains: [],
        unrestricted: true,
        httpProxyPort: 3128,
      },
    }).then(
      () => undefined,
      (e: unknown) => e as Error,
    )

    expect(error?.message).toContain('network.httpProxyPort')
    expect(SandboxManager.getConfig()).toBeUndefined()
  })

  it('rejects masked credentials passed straight to initialize()', async () => {
    await SandboxManager.reset()

    const error = await SandboxManager.initialize({
      ...baseConfig(true),
      credentials: {
        allowPlaintextInject: true,
        envVars: [{ name: 'TOKEN', mode: 'mask' }],
      },
    }).then(
      () => undefined,
      (e: unknown) => e as Error,
    )

    expect(error?.message).toContain('mask')
    expect(SandboxManager.getConfig()).toBeUndefined()
  })

  it('does not change the topology when updateConfig flips the flag', async () => {
    await SandboxManager.reset()
    await SandboxManager.initialize(baseConfig(true))

    SandboxManager.updateConfig(baseConfig(false))

    // The proxy is created at initialize(); updateConfig only warns.
    expect(SandboxManager.getProxyPort()).toBeUndefined()
  })

  it.if(isMacOS)(
    'returns the bare command when the filesystem is disabled too',
    async () => {
      await SandboxManager.reset()
      await SandboxManager.initialize({
        network: { allowedDomains: [], deniedDomains: [], unrestricted: true },
        filesystem: {
          disabled: true,
          denyRead: [],
          allowWrite: [],
          denyWrite: [],
        },
      })

      // Nothing left to restrict, so wrapCommandWithSandboxMacOS returns
      // the command unwrapped.
      const wrapped = await SandboxManager.wrapWithSandbox('echo unwrapped')
      expect(wrapped).toBe('echo unwrapped')

      const result = run(wrapped)
      expect(result.status).toBe(0)
      expect(result.stdout).toContain('unwrapped')
    },
  )
})
