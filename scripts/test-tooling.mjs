// Socket-free regression checks. Run with: bun scripts/test-tooling.mjs
// All stores and tools below are disposable fixtures, never api/data.json.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, chmodSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sandbox = mkdtempSync(join(tmpdir(), 'training tracker tooling-'));
const shell = process.env.TEST_BASH || '/bin/bash';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
let checks = 0;

function fixture(name) {
  const root = join(sandbox, name);
  for (const dir of ['scripts', 'api', 'web', 'bin']) mkdirSync(join(root, dir), { recursive: true });
  for (const file of ['check-tools.sh', 'setup.sh', 'install-e2e-deps.sh', 'dev.sh']) {
    copyFileSync(join(repo, 'scripts', file), join(root, 'scripts', file));
    chmodSync(join(root, 'scripts', file), 0o755);
  }
  copyFileSync(join(repo, 'mise.toml'), join(root, 'mise.toml'));
  writeFileSync(join(root, 'api/data.seed.json'), '{"fixture":true}\n');
  return root;
}
function executable(root, name, body) {
  const path = join(root, 'bin', name);
  writeFileSync(path, `#!/bin/bash\nset -eu\n${body}\n`);
  chmodSync(path, 0o755);
}
function environment(root, extra = {}) {
  return { ...process.env, PATH: `${root}/bin:/usr/bin:/bin`, CLAUDE_CODE_REMOTE: '', FIXTURE: root, ...extra };
}
function run(root, script, extra = {}) {
  return spawnSync(shell, [join(root, 'scripts', script)], {
    cwd: tmpdir(), env: environment(root, extra), encoding: 'utf8', timeout: 10000,
  });
}
function check(name, result, status, message) {
  assert.equal(result.status, status, `${name}: ${result.stderr || result.error}`);
  if (message) assert.match(result.stderr, message);
  checks++;
  console.log(`pass: ${name}`);
}

try {
  const root = fixture('setup');
  executable(root, 'zig', 'echo "${ZIG_VERSION:-0.16.0}"');
  executable(root, 'bun', `
if [[ "$1" == --version ]]; then echo "\${BUN_VERSION:-1.3.14}"; exit; fi
echo "$*" >> "$FIXTURE/calls"
if [[ "$1" == install ]]; then exit "\${INSTALL_STATUS:-0}"; fi
exit "\${BROWSER_STATUS:-0}"`);
  writeFileSync(join(root, 'web/package.json'), '{}\n');
  writeFileSync(join(root, 'web/bun.lock'), 'fixture lock\n');
  const before = ['web/package.json', 'web/bun.lock', 'api/data.seed.json'].map(p => readFileSync(join(root, p), 'utf8'));
  check('setup from outside repository', run(root, 'setup.sh'), 0);
  check('setup repeated', run(root, 'setup.sh'), 0);
  assert.deepEqual(['web/package.json', 'web/bun.lock', 'api/data.seed.json'].map(p => readFileSync(join(root, p), 'utf8')), before);
  assert.equal(existsSync(join(root, 'api/data.json')), false);
  assert.equal(readFileSync(join(root, 'calls'), 'utf8'), 'install --frozen-lockfile\nnode_modules/@playwright/test/cli.js install chromium\n'.repeat(2));
  check('wrong Zig', run(root, 'setup.sh', { ZIG_VERSION: '0.15.0' }), 1, /zig 0.16.0 required/);
  check('wrong Bun', run(root, 'setup.sh', { BUN_VERSION: '1.0.0' }), 1, /bun 1.3.14 required/);
  check('dependency failure', run(root, 'setup.sh', { INSTALL_STATUS: '17' }), 17);
  check('browser failure', run(root, 'setup.sh', { BROWSER_STATUS: '18' }), 1, /Chromium installation failed/);
  check('remote hook delegates setup', run(root, 'install-e2e-deps.sh', { CLAUDE_CODE_REMOTE: 'true', BROWSER_STATUS: '18' }), 1, /Chromium installation failed/);
  rmSync(join(root, 'bin/zig'));
  check('missing Zig', run(root, 'setup.sh'), 1, /zig 0.16.0 is required/);
  check('local hook needs no tools', run(root, 'install-e2e-deps.sh'), 0);
  executable(root, 'zig', 'echo 0.16.0');
  rmSync(join(root, 'bin/bun'));
  check('missing Bun', run(root, 'setup.sh'), 1, /bun 1.3.14 is required/);

  for (const [name, fail, status, signal] of [
    ['API failure', 'zig', 23, null], ['web failure', 'bun', 24, null],
    ['clean server exit', 'zig', 0, null], ['interrupt', '', 130, 'SIGINT'],
    ['termination', '', 143, 'SIGTERM'],
  ]) {
    const root = fixture(name);
    // An existing store must survive startup; the first case also checks seeding.
    if (name !== 'API failure') writeFileSync(join(root, 'api/data.json'), 'existing fixture\n');
    for (const service of ['zig', 'bun']) executable(root, service, `
echo $$ >> "$FIXTURE/pids"
sleep 60 &
child=$!
echo "$child" >> "$FIXTURE/pids"
trap 'wait "$child" 2>/dev/null || true; exit 0' TERM
if [[ "\${FAIL_SERVICE:-}" == ${service} ]]; then
  sleep 0.5
  exit "$FAIL_STATUS"
fi
wait "$child"`);
    let output = '';
    const proc = spawn(shell, [join(root, 'scripts/dev.sh')], {
      cwd: tmpdir(), env: environment(root, { FAIL_SERVICE: fail, FAIL_STATUS: String(status) }),
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    proc.stdout.on('data', data => { output += data; });
    proc.stderr.on('data', data => { output += data; });
    const finished = new Promise(resolve => proc.on('exit', (code, sig) => resolve({ code, sig })));
    const watchdog = setTimeout(() => proc.kill('SIGKILL'), 12000);
    try {
      for (let attempt = 0; attempt < 100; attempt++) {
        if (existsSync(join(root, 'pids')) && readFileSync(join(root, 'pids'), 'utf8').trim().split('\n').length === 4) break;
        await pause(20);
      }
      assert.equal(readFileSync(join(root, 'pids'), 'utf8').trim().split('\n').length, 4, output);
      if (signal) proc.kill(signal);
      const result = await finished;
      assert.equal(result.code, status, `${name}: ${JSON.stringify(result)}\n${output}`);
      const pids = readFileSync(join(root, 'pids'), 'utf8').trim().split('\n').map(Number);
      for (let attempt = 0; attempt < 100 && pids.some(alive); attempt++) await pause(20);
      assert.deepEqual(pids.filter(alive), [], `${name}: surviving processes\n${output}`);
      assert.equal(readFileSync(join(root, 'api/data.json'), 'utf8'), name === 'API failure' ? '{"fixture":true}\n' : 'existing fixture\n');
      checks++;
      console.log(`pass: ${name}, exit status, process-tree cleanup, store preservation`);
    } finally {
      clearTimeout(watchdog);
      if (alive(proc.pid)) proc.kill('SIGKILL');
      if (existsSync(join(root, 'pids'))) for (const pid of readFileSync(join(root, 'pids'), 'utf8').trim().split('\n').map(Number)) {
        try { process.kill(pid, 'SIGKILL'); } catch {}
      }
    }
  }
  console.log(`${checks} tooling checks passed (${shell}).`);
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}
