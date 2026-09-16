const assert = require('node:assert/strict');
const fs = require('node:fs');

const script = fs.readFileSync(0, 'utf8');
const run = new (Object.getPrototypeOf(async function () {}).constructor)('github', 'context', 'core', script);
const environmentNames = ['OPENARM_RUN_ID', 'OPENARM_TRIAL_RESULT', 'OPENARM_DISCOVERY'];
const saved = Object.fromEntries(environmentNames.map((name) => [name, process.env[name]]));
let checks = 0;

async function scenario(options = {}) {
  process.env.OPENARM_RUN_ID = options.runId ?? '12345';
  process.env.OPENARM_TRIAL_RESULT = options.result ?? 'failure';
  process.env.OPENARM_DISCOVERY = options.discovery ?? 'false';
  const context = {
    repo: { owner: 'sykuang', repo: 'OpenArm' },
    eventName: options.event ?? 'workflow_dispatch',
    serverUrl: 'https://github.com',
  };
  const marker = '<!-- openarm-human-help:12345 -->';
  const existing = {
    number: 7, title: 'Human edited title', body: marker,
    user: { login: 'github-actions[bot]' }, state: options.state ?? 'open',
  };
  const calls = [];
  const messages = [];
  const github = { rest: { issues: {
    listForRepo: async (args) => {
      calls.push({ method: 'GET', args });
      assert.equal(args.owner, 'sykuang');
      assert.equal(args.repo, 'OpenArm');
      assert.equal(args.state, 'all');
      assert.equal(args.creator, 'github-actions[bot]');
      assert.equal(args.per_page, 100);
      assert.equal(args.request.timeout, 15000);
      if (options.listError) throw options.listError;
      let data = [];
      if (options.existing && args.page === (options.existingPage ?? 1)) data = [existing];
      if (options.spoof) data = [
        { ...existing, user: { login: 'someone-else' } },
        { ...existing, pull_request: {} },
        { ...existing, body: '<!-- openarm-human-help:99999 -->' },
      ];
      const more = options.unbounded || args.page < (options.existingPage ?? 1);
      return { status: 200, data, headers: { link: more ? '<https://api.github.com/next>; rel="next"' : '' } };
    },
    create: async (args) => {
      calls.push({ method: 'POST', args });
      assert.equal(args.owner, 'sykuang');
      assert.equal(args.repo, 'OpenArm');
      assert.equal(args.request.timeout, 15000);
      if (options.createError) throw options.createError;
      return { status: 201, data: { number: options.badNumber ? 0 : 8 } };
    },
  } } };
  let error;
  let result;
  try { result = await run(github, context, { info: (value) => messages.push(value) }); }
  catch (caught) { error = caught; }
  return { calls, messages, error, result, marker };
}

async function check(name, options, verify) {
  const outcome = await scenario(options);
  try { verify(outcome); }
  catch (error) { throw new Error(`${name}: ${error.message}`, { cause: error }); }
  checks++;
}

(async () => {
  try {
    await check('Failure creates a hosting-repository help issue', {}, ({ calls, result, error, marker }) => {
      assert.ifError(error);
      assert.equal(calls.length, 2);
      assert.equal(result.status, 'created');
      assert.equal(result.issueUrl, 'https://github.com/sykuang/OpenArm/issues/8');
      assert.match(calls[1].args.title, /12345/);
      assert.ok(calls[1].args.body.includes(marker));
      assert.match(calls[1].args.body, /failed/i);
      assert.match(calls[1].args.body, /https:\/\/github\.com\/sykuang\/OpenArm\/actions\/runs\/12345/);
      assert.match(calls[1].args.body, /artifact/i);
      assert.match(calls[1].args.body, /does not authorize/i);
    });
    await check('Successful discovery requires human review', { result: 'success', discovery: 'true' }, ({ calls, error }) => {
      assert.ifError(error);
      assert.match(calls[1].args.body, /review.*candidate/i);
      assert.match(calls[1].args.body, /no candidate/i);
    });
    for (const state of ['open', 'closed']) {
      await check(`Rerun reuses ${state} issue without changes`, { existing: true, state }, ({ calls, result, error }) => {
        assert.ifError(error);
        assert.equal(calls.length, 1);
        assert.equal(result.status, 'reused');
        assert.equal(result.issueUrl, 'https://github.com/sykuang/OpenArm/issues/7');
      });
    }
    await check('Find existing issue beyond the first page', { existing: true, existingPage: 2 }, ({ calls, result, error }) => {
      assert.ifError(error);
      assert.equal(calls.length, 2);
      assert.deepEqual(calls.map((call) => call.args.page), [1, 2]);
      assert.equal(result.status, 'reused');
    });
    await check('Do not reuse a PR, another author or another run', { spoof: true }, ({ calls, result, error }) => {
      assert.ifError(error);
      assert.equal(calls.at(-1).method, 'POST');
      assert.equal(result.status, 'created');
    });
    await check('Incomplete inventory cannot create duplicates', { unbounded: true }, ({ calls, error }) => {
      assert.match(error.message, /inventory|1000|1,000/i);
      assert.equal(calls.length, 10);
      assert.ok(calls.every((call) => call.method === 'GET'));
    });
    for (const status of [401, 403, 404, 429, 500]) {
      await check(`HTTP ${status} is explicit, not a reason to create anyway`,
        { listError: Object.assign(new Error('credential-secret'), { status }) }, ({ calls, error }) => {
          assert.match(error.message, new RegExp(`HTTP ${status}`));
          assert.doesNotMatch(error.message, /credential-secret/);
          assert.equal(calls.length, 1);
        });
    }
    await check('Ambiguous creation is never automatically retried',
      { createError: new Error('credential-secret connection lost') }, ({ calls, error }) => {
        assert.ok(error);
        assert.doesNotMatch(error.message, /credential-secret/);
        assert.match(error.message, /retry|retried/i);
        assert.equal(calls.filter((call) => call.method === 'POST').length, 1);
      });
    await check('An invalid creation response is not success', { badNumber: true }, ({ calls, error }) => {
      assert.ok(error);
      assert.equal(calls.filter((call) => call.method === 'POST').length, 1);
    });
    for (const options of [
      { result: 'success' }, { result: 'cancelled' }, { result: 'skipped' },
      { event: 'pull_request' }, { runId: '../other' }, { runId: '123\ninjected' },
    ]) {
      await check('Out-of-scope reporting is rejected before API calls', options, ({ calls, error }) => {
        assert.ok(error);
        assert.equal(calls.length, 0);
      });
    }
    console.log(`${checks} human-help issue checks passed.`);
  } finally {
    for (const name of environmentNames) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
