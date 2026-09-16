const assert = require('node:assert/strict');
const test = require('node:test');
const { classifyLauncherEvidence } = require('./agent-browser-wrapper.cjs');

const checks = Array.from({ length: 16 }, (_, index) => ({
  name: index < 2 ? ['empty-arm64', 'directory-arm64'][index] : `unaffected-${index}`,
  defect: index < 2, passed: index >= 2,
}));
function launches(stderr) {
  return ['clean-version', 'clean-help', 'empty-version', 'empty-help'].map((name) => ({
    name, passed: name.startsWith('clean-'), exitCode: name.startsWith('clean-') ? 0 : 1,
    error: null, stderr: name.startsWith('empty-') ? stderr : '',
  }));
}

test('admit both synchronous Node spawn exceptions and asynchronous wrapper errors', () => {
  for (const error of ['Error: spawn EFTYPE', 'Error executing binary: spawn EFTYPE',
    'Error: spawn ENOEXEC', 'Error executing binary: spawn EINVAL']) {
    assert.equal(classifyLauncherEvidence(checks, launches(error)), true, error);
  }
});

test('do not admit unknown failures, missing evidence, or broken clean-package launches', () => {
  for (const error of ['Error: spawn ENOENT', 'Error: spawn EACCES', 'unrelated EFTYPE text', 'Error: spawn EFTYPEsuffix']) {
    assert.equal(classifyLauncherEvidence(checks, launches(error)), false, error);
  }
  for (const change of [
    (runs) => { runs.pop(); },
    (runs) => { runs[0].passed = false; },
    (runs) => { runs[2].exitCode = 0; },
    (runs) => { runs[2].error = 'timeout'; },
  ]) {
    const runs = launches('Error: spawn EFTYPE'); change(runs);
    assert.equal(classifyLauncherEvidence(checks, runs), false);
  }
  assert.equal(classifyLauncherEvidence([], launches('Error: spawn EFTYPE')), false);
  assert.equal(classifyLauncherEvidence(checks.slice(1), launches('Error: spawn EFTYPE')), false);
  const broken = structuredClone(checks); broken[4].passed = false;
  assert.equal(classifyLauncherEvidence(broken, launches('Error: spawn EFTYPE')), false);
});
