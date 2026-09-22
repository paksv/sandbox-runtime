import { expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { wrapCommandWithSandboxLinux } from '../../src/sandbox/linux-sandbox-utils.js'

test('socket blocking alone rejects a non-executable helper', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'srt-helper-'))
  const helper = join(directory, 'apply-seccomp')
  try {
    writeFileSync(helper, '#!/bin/sh\nexit 0\n', { mode: 0o600 })
    await expect(
      wrapCommandWithSandboxLinux({
        command: 'true',
        needsNetworkRestriction: false,
        allowAllUnixSockets: false,
        seccompConfig: { applyPath: helper },
      }),
    ).rejects.toThrow('apply-seccomp is not executable')
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('allow-all without other restrictions does not require a helper', async () => {
  expect(
    await wrapCommandWithSandboxLinux({
      command: 'true',
      needsNetworkRestriction: false,
      allowAllUnixSockets: true,
      seccompConfig: { applyPath: '/missing/apply-seccomp' },
    }),
  ).toBe('true')
})