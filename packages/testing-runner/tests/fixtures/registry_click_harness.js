#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

function chromeBinary() {
  const candidates = [
    process.env.FKST_TEST_CHROME_BIN,
    process.env.CHROME_BIN,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/opt/google/chrome/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForDevToolsPort(userDataDir, chrome) {
  const activePortPath = path.join(userDataDir, 'DevToolsActivePort');
  for (let attempt = 0; attempt < 300; attempt += 1) {
    if (chrome.exitCode !== null) throw new Error(`Chrome exited before CDP became ready: ${chrome.exitCode}`);
    if (fs.existsSync(activePortPath)) {
      const port = Number(fs.readFileSync(activePortPath, 'utf8').split(/\r?\n/)[0]);
      if (Number.isInteger(port) && port > 0 && port <= 65535) return port;
    }
    await delay(50);
  }
  throw new Error('Chrome did not publish DevToolsActivePort');
}

async function main() {
  const statePath = argument('--state');
  if (!statePath) throw new Error('--state is required');
  const fixture = fs.readFileSync(path.join(__dirname, 'registry_click.html'));
  const chromePath = chromeBinary();
  if (!chromePath) throw new Error('Chrome or Chromium is required for the registry click acceptance test');

  const server = http.createServer((request, response) => {
    if (request.url !== '/registry-click') {
      response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('not found');
      return;
    }
    response.writeHead(200, {
      'cache-control': 'no-store',
      'content-type': 'text/html; charset=utf-8',
    });
    response.end(fixture);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });

  const address = server.address();
  const baseUrl = `http://127.0.0.1:${address.port}/registry-click`;
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fkst-registry-click-'));
  const chrome = spawn(chromePath, [
    '--headless=new',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-extensions',
    '--disable-gpu',
    '--disable-sync',
    '--metrics-recording-only',
    '--no-first-run',
    '--no-sandbox',
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`,
    baseUrl,
  ], { stdio: 'ignore' });

  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    server.close(() => {});
    if (chrome.exitCode === null) chrome.kill('SIGTERM');
    fs.rmSync(userDataDir, { recursive: true, force: true });
    process.exit(0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);

  const cdpPort = await waitForDevToolsPort(userDataDir, chrome);
  fs.writeFileSync(statePath, JSON.stringify({
    base_url: baseUrl,
    cdp_url: `http://127.0.0.1:${cdpPort}`,
  }));
}

main().catch((error) => {
  const statePath = argument('--state');
  if (statePath) fs.writeFileSync(statePath, JSON.stringify({ error: String(error.message || error) }));
  process.exitCode = 1;
});
