'use strict';

// Starts the real app in Electron's bundled Chromium, points it at a local page, and checks
// that a notification created by the page reaches the main process with the expected text.
// Runs headless (no display needed) on Linux, and on macOS too.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const APP_DIR = path.join(__dirname, '..');
const ELECTRON = require('electron'); // path to the Electron binary that npm installed

// Stands in for Google Voice. It creates one notification once the preload shim is in place,
// the way the real page does when a new text arrives.
const FIXTURE_PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>Fixture</title></head>
<body>
<script>
  function sendWhenShimReady() {
    if (!window.__gvNotificationShim) return setTimeout(sendWhenShimReady, 50);
    new Notification('Alice', { body: 'Your code is 123456', tag: 'msg-1' });
  }
  window.addEventListener('load', sendWhenShimReady);
</script>
</body></html>`;

function startFixtureServer() {
  return new Promise((resolve) => {
    const server = http.createServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end(FIXTURE_PAGE);
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

async function waitFor(condition, timeoutMs, describeTimeout) {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(describeTimeout());
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

test('a notification from the page reaches the app through Chromium', { timeout: 180_000 }, async () => {
  const server = await startFixtureServer();
  const { port } = server.address();
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gv-test-'));

  const child = spawn(ELECTRON, [
    APP_DIR,
    '--no-sandbox', // Electron's sandbox needs a setuid helper that a test run does not have
    '--disable-gpu',
    '--ozone-platform=headless',
    `--user-data-dir=${userDataDir}`,
  ], {
    env: { ...process.env, GV_TEST: '1', GV_URL: `http://127.0.0.1:${port}/` },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  const events = [];
  let stdoutBuffer = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdoutBuffer += chunk;
    const lines = stdoutBuffer.split('\n');
    stdoutBuffer = lines.pop();
    for (const line of lines) {
      if (line.startsWith('GV_EVENT ')) events.push(JSON.parse(line.slice('GV_EVENT '.length)));
    }
  });
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  const find = (name) => events.find((event) => event.event === name);
  try {
    await waitFor(
      () => find('page-state') && find('notify'),
      150_000,
      () => `timed out. events: ${JSON.stringify(events)}\nstderr (tail):\n${stderr.slice(-4000)}`,
    );

    const pageState = find('page-state');
    assert.ok(pageState.userAgent.includes('Chrome/'), `user agent: ${pageState.userAgent}`);
    assert.doesNotMatch(pageState.userAgent, /Electron/);
    assert.ok(!pageState.brands.includes('Electron'), `brands: ${pageState.brands}`);
    assert.equal(pageState.shimInstalled, true);
    assert.equal(pageState.notificationClass, 'GVNotification');
    assert.equal(pageState.permission, 'granted');

    const notify = find('notify');
    assert.deepEqual(
      { title: notify.title, body: notify.body },
      { title: 'Alice', body: 'Your code is 123456' },
    );
    assert.equal(find('page-error'), undefined);
  } finally {
    child.kill();
    server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }
});
