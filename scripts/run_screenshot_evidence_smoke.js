#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');
const { once } = require('events');
const { spawn, spawnSync } = require('child_process');

const [bin, workspace, repositoryRoot] = process.argv.slice(2);
if (!bin || !workspace || !repositoryRoot) {
  throw new Error('usage: run_screenshot_evidence_smoke.js <fkst-bin> <workspace> <repository-root>');
}

const artifactRoot = '.testing/runs/screenshot-evidence-smoke';
const fixture = fs.readFileSync(path.join(repositoryRoot, 'scripts/fixtures/screenshot-evidence/app/dashboard/index.html'));
const { captureFailureScreenshot } = require(path.join(repositoryRoot, 'libraries/testing_runtime/bin/fkst-testing-runtime.js'));
const twoPixelPng = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAADklEQVR4nGP4DwUMMAYAj4IP8TylVlEAAAAASUVORK5CYII=';

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function reservePort() {
  const server = net.createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function chromeBinary() {
  if (process.env.FKST_CHROME_BIN) return process.env.FKST_CHROME_BIN;
  for (const candidate of ['google-chrome', 'chromium', 'chromium-browser']) {
    const resolved = spawnSync('sh', ['-c', `command -v ${candidate}`], { encoding: 'utf8' });
    if (resolved.status === 0 && resolved.stdout.trim()) return resolved.stdout.trim();
  }
  const macChrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  return fs.existsSync(macChrome) ? macChrome : '';
}

async function waitForHttp(url, label) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const ready = await new Promise((resolve) => {
      const request = http.get(url, (response) => {
        response.resume();
        resolve(response.statusCode >= 200 && response.statusCode < 400);
      });
      request.setTimeout(1000, () => request.destroy());
      request.on('error', () => resolve(false));
    });
    if (ready) return;
    await delay(200);
  }
  throw new Error(`${label} did not become ready at ${url}`);
}

async function terminateProcessGroup(child) {
  if (!child || child.exitCode !== null) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch (_error) {
    child.kill('SIGTERM');
  }
  await Promise.race([once(child, 'exit'), delay(2000)]);
  if (child.exitCode === null) {
    try {
      process.kill(-child.pid, 'SIGKILL');
    } catch (_error) {
      child.kill('SIGKILL');
    }
  }
}

function runChild(command, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, options);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (signal) reject(new Error(`${command} terminated by ${signal}`));
      else resolve(code);
    });
  });
}

async function verifyGeometryRaceFailsClosed() {
  let boxModelCalls = 0;
  const lifecycleStates = [];
  const cdp = {
    async send(method, params = {}) {
      if (method === 'Page.setWebLifecycleState') lifecycleStates.push(params.state);
      if (method === 'DOM.getDocument') return { root: { nodeId: 1 } };
      if (method === 'Page.getLayoutMetrics') {
        return { cssVisualViewport: { pageX: 0, pageY: 0, clientWidth: 2, clientHeight: 2 } };
      }
      if (method === 'DOM.querySelectorAll') return { nodeIds: [2] };
      if (method === 'DOM.getBoxModel') {
        boxModelCalls += 1;
        const border = boxModelCalls === 1 ? [0, 0, 1, 0, 1, 1, 0, 1] : [1, 1, 2, 1, 2, 2, 1, 2];
        return { model: { border } };
      }
      if (method === 'Page.captureScreenshot') return { data: twoPixelPng };
      return {};
    },
  };
  const originalDirectory = process.cwd();
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'fkst-screenshot-race-'));
  let rejected = false;
  try {
    process.chdir(temporaryDirectory);
    await captureFailureScreenshot(cdp, {
      artifact_root: '.testing/runs/geometry-race',
      redaction_selectors: ['[data-fkst-sensitive]'],
    });
  } catch (error) {
    rejected = error.message === 'screenshot redaction geometry changed during capture';
  } finally {
    process.chdir(originalDirectory);
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
  if (!rejected || boxModelCalls !== 2 || lifecycleStates.join(',') !== 'frozen,active') {
    throw new Error('screenshot redaction accepted mutable geometry-to-raster state');
  }
}

async function main() {
  await verifyGeometryRaceFailsClosed();
  const chrome = chromeBinary();
  if (!chrome) throw new Error('Chrome/Chromium is required for screenshot evidence smoke');
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'fkst-screenshot-chrome-'));
  const chromeLogPath = path.join(path.dirname(workspace), 'screenshot-evidence-chrome.log');
  const chromeLog = fs.openSync(chromeLogPath, 'w');
  const cdpPort = await reservePort();
  const server = http.createServer((request, response) => {
    if (request.url === '/app/dashboard/' || request.url === '/app/dashboard/index.html') {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-length': fixture.length });
      response.end(fixture);
      return;
    }
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('not found');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const httpPort = server.address().port;
  const chromeProcess = spawn(chrome, [
    '--headless=new',
    '--remote-debugging-address=127.0.0.1',
    `--remote-debugging-port=${cdpPort}`,
    `--user-data-dir=${profile}`,
    '--window-size=800,600',
    '--force-device-scale-factor=1',
    '--no-first-run',
    '--no-default-browser-check',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    'about:blank',
  ], { detached: true, stdio: ['ignore', chromeLog, chromeLog] });

  try {
    await waitForHttp(`http://127.0.0.1:${cdpPort}/json/version`, 'Chrome CDP');
    fs.mkdirSync(path.join(workspace, artifactRoot), { recursive: true });
    const runStatus = await runChild(bin, [
      'run',
      path.join(workspace, 'departments/screenshot_evidence_smoke/main.lua'),
      '--project-root', workspace,
      '--package-root', workspace,
      '--owner-namespace', 'testing-runner',
      '--event', '{"queue":"screenshot_evidence_smoke","payload":{}}',
    ], {
      cwd: workspace,
      env: {
        ...process.env,
        FKST_SCREENSHOT_BASE_URL: `http://127.0.0.1:${httpPort}/app`,
        FKST_SCREENSHOT_CDP_URL: `http://127.0.0.1:${cdpPort}`,
        FKST_SCREENSHOT_ARTIFACT_ROOT: artifactRoot,
      },
      stdio: 'inherit',
    });
    if (runStatus !== 0) throw new Error(`screenshot evidence pipeline exited ${runStatus}`);
    const verify = spawnSync(process.execPath, [
      path.join(repositoryRoot, 'scripts/verify_screenshot_evidence.js'),
      workspace,
      artifactRoot,
    ], { stdio: 'inherit' });
    if (verify.status !== 0) throw new Error(`screenshot evidence verification exited ${verify.status}`);
  } catch (error) {
    if (fs.existsSync(chromeLogPath)) process.stderr.write(fs.readFileSync(chromeLogPath, 'utf8'));
    throw error;
  } finally {
    await terminateProcessGroup(chromeProcess);
    await new Promise((resolve) => server.close(resolve));
    fs.closeSync(chromeLog);
    if (process.platform === 'darwin') spawnSync('xattr', ['-cr', profile], { stdio: 'ignore' });
    fs.rmSync(profile, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`screenshot-evidence-smoke: ${error.message}\n`);
  process.exitCode = 1;
});
