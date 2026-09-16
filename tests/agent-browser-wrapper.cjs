const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { readFileSync, writeFileSync, statSync } = require('node:fs');
const { join, basename } = require('node:path');
const { pathToFileURL } = require('node:url');

function classifyLauncherEvidence(checks, launches) {
  const clean = launches.filter((launch) => launch.name.startsWith('clean-'));
  const empty = launches.filter((launch) => launch.name.startsWith('empty-'));
  return checks.length === 16 && clean.length === 2 && empty.length === 2
    && checks.filter((check) => !check.defect && check.name !== 'stat-error').every((check) => check.passed)
    && checks.filter((check) => check.defect).length === 2
    && checks.filter((check) => check.defect).every((check) => !check.passed)
    && clean.every((launch) => launch.passed)
    && empty.every((launch) => launch.exitCode === 1 && !launch.error
      && /(?:Error executing binary:.*(?:EFTYPE|ENOEXEC|EINVAL)|Error: spawn (?:EFTYPE|ENOEXEC|EINVAL)\b)/i.test(launch.stderr));
}

module.exports = { classifyLauncherEvidence };

function main() {
  const [wrapper, resultPath, fixture, version] = process.argv.slice(2);
  if (!wrapper || !resultPath) throw new Error('Usage: node agent-browser-wrapper.cjs WRAPPER RESULT [NATIVE_FIXTURE VERSION]');
  const x64 = 'agent-browser-win32-x64.exe';
  const arm64 = 'agent-browser-win32-arm64.exe';
  const args = ['open', 'https://example.invalid/a b', '--session', 'two words'];
  const cases = [
    { name: 'missing-arm64', files: { [x64]: 10 }, expected: x64 },
    { name: 'empty-arm64', files: { [x64]: 10, [arm64]: 0 }, expected: x64, defect: true },
    { name: 'directory-arm64', files: { [x64]: 10, [arm64]: 'directory' }, expected: x64, defect: true },
    { name: 'native-preferred', files: { [x64]: 10, [arm64]: 10 }, expected: arm64 },
    { name: 'native-only', files: { [arm64]: 10 }, expected: arm64 },
    { name: 'windows-x64', arch: 'x64', files: { [x64]: 10 }, expected: x64 },
    { name: 'windows-aarch64', arch: 'aarch64', files: { [x64]: 10 }, expected: x64 },
    { name: 'mac-arm64', platform: 'darwin', files: { 'agent-browser-darwin-arm64': 10 }, expected: 'agent-browser-darwin-arm64' },
    { name: 'linux-x64', platform: 'linux', arch: 'x64', files: { 'agent-browser-linux-x64': 10 }, expected: 'agent-browser-linux-x64' },
    { name: 'linux-musl', platform: 'linux', musl: true, files: { 'agent-browser-linux-musl-arm64': 10 }, expected: 'agent-browser-linux-musl-arm64' },
    { name: 'missing-all', files: {}, error: 'No binary found' },
    { name: 'unsupported-arch', arch: 'ia32', files: {}, error: 'Unsupported platform' },
    { name: 'unsupported-platform', platform: 'freebsd', files: {}, error: 'Unsupported platform' },
    { name: 'child-exit', files: { [x64]: 10 }, expected: x64, exit: 7 },
    { name: 'spawn-error', files: { [x64]: 10 }, expected: x64, error: 'Error executing binary', spawnError: true },
    { name: 'stat-error', files: { [arm64]: 'denied', [x64]: 10 }, error: 'EACCES' },
  ];
  const checks = cases.map((test) => {
    const script = `
  import { createRequire, syncBuiltinESMExports } from 'node:module';
  const require = createRequire(import.meta.url);
  const fs = require('node:fs'), os = require('node:os'), cp = require('node:child_process');
  const { basename } = require('node:path');
  const test = ${JSON.stringify(test)};
  os.platform = () => test.platform || 'win32';
  os.arch = () => test.arch || 'arm64';
  fs.existsSync = (path) => Object.hasOwn(test.files, basename(path));
  fs.statSync = fs.lstatSync = (path, options) => {
    const entry = test.files[basename(path)];
    if (entry === undefined || entry === 'denied') {
      if (entry === undefined && options?.throwIfNoEntry === false) return undefined;
      const code = entry === 'denied' ? 'EACCES' : 'ENOENT';
      throw Object.assign(new Error(code + ': ' + path), { code });
    }
    return { size: typeof entry === 'number' ? entry : 0, isFile: () => typeof entry === 'number' };
  };
  fs.accessSync = () => {};
  fs.chmodSync = () => {};
  cp.execSync = () => test.musl ? 'musl libc' : 'GNU libc';
  cp.spawn = (path, args, options) => {
    process.stdout.write(JSON.stringify({ binary: basename(path), args, options }));
    return { on(event, callback) {
      if (event === 'error' && test.spawnError) callback(new Error('fixture spawn failure'));
      if (event === 'close') callback(test.exit || 0);
      return this;
    }};
  };
  process.argv = ['node', ${JSON.stringify(wrapper)}, ...${JSON.stringify(args)}];
  syncBuiltinESMExports();
  await import(${JSON.stringify(pathToFileURL(wrapper).href)});
  `;
    const run = spawnSync(process.execPath, ['--input-type=module', '--eval', script], { encoding: 'utf8', timeout: 10000 });
    let error = null;
    try {
      if (run.error) throw run.error;
      assert.equal(run.status, test.error ? 1 : (test.exit || 0), run.stderr);
      if (test.error) assert.ok(run.stderr.includes(test.error), run.stderr);
      if (test.expected) {
        const selected = JSON.parse(run.stdout);
        assert.equal(selected.binary, test.expected);
        assert.deepEqual(selected.args, args);
        assert.deepEqual(selected.options, { stdio: 'inherit', windowsHide: false });
      } else {
        assert.equal(run.stdout, '');
      }
    } catch (failure) { error = failure.message; }
    return { name: test.name, defect: Boolean(test.defect), passed: error === null, error };
  });

  const result = {
    schemaVersion: 1, nativeVerified: false, compatibilityVerified: false, faultReproduced: false,
    host: { platform: process.platform, nodeArchitecture: process.arch, nodeVersion: process.version },
    scope: 'Launcher regression fixture and version/help only; x64 emulation, not a native port or browser session.',
    checks, launches: [], binary: null, reason: '',
  };
  if (fixture) {
    assert.equal(process.platform, 'win32', 'Native fixture requires Windows');
    assert.equal(process.arch, 'arm64', 'Native fixture requires Arm64 Node.js');
    assert.match(version, /^\d+\.\d+\.\d+$/);
    const executable = join(fixture, 'bin', x64);
    const hash = () => createHash('sha256').update(readFileSync(executable)).digest('hex');
    const originalHash = hash();
    for (const state of ['clean', 'empty']) {
      if (state === 'empty') writeFileSync(join(fixture, 'bin', arm64), Buffer.alloc(0), { flag: 'wx' });
      for (const flag of ['--version', '--help']) {
        const run = spawnSync(process.execPath, [wrapper, flag], { cwd: fixture, encoding: 'utf8', timeout: 20000 });
        const expected = flag === '--version' ? `agent-browser ${version}` : 'Usage:';
        result.launches.push({
          name: `${state}-${flag.slice(2)}`, exitCode: run.status, signal: run.signal,
          passed: !run.error && run.status === 0 && run.stdout.includes(expected),
          stdout: run.stdout, stderr: run.stderr, error: run.error ? run.error.message : null,
        });
      }
    }
    assert.equal(hash(), originalHash, 'Published executable must remain unchanged');
    assert.equal(statSync(join(fixture, 'bin', arm64)).size, 0, 'Regression stub must stay empty');
    result.binary = { name: basename(executable), sha256: originalHash, size: statSync(executable).size };
    result.compatibilityVerified = checks.every((check) => check.passed) && result.launches.every((launch) => launch.passed);
    // Only the demonstrated empty-file launch error admits an editing attempt.
    result.faultReproduced = classifyLauncherEvidence(checks, result.launches);
  }
  result.reason = result.compatibilityVerified
    ? 'Launcher contracts and actual version/help passed on native Arm64 Node with the unchanged published x64 PE.'
    : result.faultReproduced
      ? 'Clean-package launch works; the explicit zero-byte Arm64-file fixture fails. No clean-install or browser-session defect is claimed.'
      : 'Launcher evidence does not meet the reviewed compatibility gate; inspect the checks and launch output.';
  writeFileSync(resultPath, JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({ checks: checks.length, failures: checks.filter((check) => !check.passed).map((check) => check.name),
    compatibilityVerified: result.compatibilityVerified, faultReproduced: result.faultReproduced }));
}

if (require.main === module) main();
