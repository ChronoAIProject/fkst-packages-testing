'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { processGroupUsage } = require('./platform');

function parseMetrics(stderr) {
  const text = String(stderr || '');
  if (process.platform === 'darwin') {
    const user = text.match(/(?:^|\n)\s*(?:user\s+([0-9.]+)|([0-9.]+)\s+user)\b/);
    const system = text.match(/(?:^|\n)\s*(?:sys\s+([0-9.]+)|([0-9.]+)\s+sys)\b/);
    const rss = text.match(/(?:^|\n)\s*(\d+)\s+maximum resident set size\b/);
    if (!user || !system || !rss) return { supported: false };
    return {
      supported: true,
      cpuMillis: Math.ceil((Number(user[1] || user[2]) + Number(system[1] || system[2])) * 1000),
      maxRssBytes: Number(rss[1]),
    };
  }
  if (process.platform === 'linux') {
    const user = text.match(/User time \(seconds\):\s*([0-9.]+)/);
    const system = text.match(/System time \(seconds\):\s*([0-9.]+)/);
    const rss = text.match(/Maximum resident set size \(kbytes\):\s*(\d+)/);
    if (!user || !system || !rss) return { supported: false };
    return {
      supported: true,
      cpuMillis: Math.ceil((Number(user[1]) + Number(system[1])) * 1000),
      maxRssBytes: Number(rss[1]) * 1024,
    };
  }
  return { supported: false };
}

function timeArgv(argv, metricsPath) {
  if (process.platform === 'darwin') return ['/usr/bin/time', ['-lp', '-o', metricsPath, ...argv]];
  if (process.platform === 'linux') return ['/usr/bin/time', ['-v', '-o', metricsPath, ...argv]];
  return null;
}

function runMeasuredCommand(argv, options = {}) {
  const metricsPath = path.join(os.tmpdir(), `environment-time-${process.pid}-${crypto.randomBytes(8).toString('hex')}`);
  const timed = timeArgv(argv, metricsPath);
  if (!timed) return Promise.resolve({ exitCode: -1, metricsSupported: false, stderr: 'resource measurement is unsupported' });
  const timeoutMs = Math.max(1, Number(options.timeoutMs) || 30_000);
  const outputBytes = Math.max(1, Number(options.outputBytes) || 64 * 1024);
  return new Promise((resolve) => {
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let outputExceeded = false;
    let outputSize = 0;
    let timedOut = false;
    let settled = false;
    let maxProcesses = 0;
    const child = spawn(timed[0], timed[1], {
      cwd: options.cwd,
      env: options.env,
      shell: false,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stop = () => {
      if (!Number.isInteger(child.pid)) return;
      try { process.kill(-child.pid, 'SIGKILL'); } catch (_error) {
        try { process.kill(child.pid, 'SIGKILL'); } catch (_ignored) {}
      }
    };
    const append = (current, chunk) => {
      const remaining = Math.max(0, outputBytes - outputSize);
      const accepted = chunk.subarray(0, remaining);
      outputSize += accepted.length;
      if (accepted.length < chunk.length) {
        outputExceeded = true;
        stop();
      }
      return Buffer.concat([current, accepted]);
    };
    child.stdout.on('data', (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on('data', (chunk) => { stderr = append(stderr, chunk); });
    const sampleProcesses = () => {
      if (!Number.isInteger(child.pid)) return;
      const usage = processGroupUsage([child.pid]);
      if (!usage.supported) return;
      maxProcesses = Math.max(maxProcesses, Math.max(0, usage.processes - 1));
    };
    const sampler = setInterval(sampleProcesses, 10);
    sampleProcesses();
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeoutMs);
    child.once('error', (error) => {
      clearTimeout(timer);
      clearInterval(sampler);
      if (settled) return;
      settled = true;
      fs.rmSync(metricsPath, { force: true });
      resolve({ exitCode: -1, pgid: child.pid, metricsSupported: false, processMetricsSupported: false,
        stdout: '', stderr: String(error.message || error), error });
    });
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      clearInterval(sampler);
      if (settled) return;
      settled = true;
      const stderrText = stderr.toString('utf8');
      let metricsText = '';
      try { metricsText = fs.readFileSync(metricsPath, 'utf8'); } catch (_error) {}
      fs.rmSync(metricsPath, { force: true });
      const metrics = parseMetrics(metricsText);
      resolve({
        exitCode: Number.isInteger(code) ? code : -1,
        pgid: child.pid,
        signal,
        stdout: stdout.toString('utf8'),
        stderr: stderrText,
        timedOut,
        outputExceeded,
        metricsSupported: metrics.supported,
        processMetricsSupported: metrics.supported,
        maxProcesses: Math.max(1, maxProcesses),
        cpuMillis: metrics.cpuMillis,
        maxRssBytes: metrics.maxRssBytes,
      });
    });
  });
}

module.exports = { parseMetrics, runMeasuredCommand };
