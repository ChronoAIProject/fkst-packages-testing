#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const store = require('./durable-host-store');
const fixed = require('../../../libraries/testing_runtime/lib/deterministic_browser');
const { check, keys, stable, sha256 } = fixed;

function read(file) {
  try {
    check(!fs.lstatSync(file).isSymbolicLink(), 'symlink-forbidden');
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
}

function context(config) {
  keys(config, 'policy grants store_root chrome_path');
  check(path.isAbsolute(config.store_root) && path.isAbsolute(config.chrome_path)
    && Array.isArray(config.grants), 'host-config-invalid');
  const root = path.resolve(config.store_root);
  // Read-only construction: do not use store.execute(record-read), which mkdirs.
  for (let current = root; ; current = path.dirname(current)) {
    if (fs.existsSync(current)) check(!fs.lstatSync(current).isSymbolicLink(), 'host-root-symlink');
    if (path.dirname(current) === current) break;
  }
  const operation = value => store.execute({ root, ...value });
  const recordFile = key => {
    check(/^fixed-browser\/[A-Za-z0-9_-]{1,96}\/(claim|intent|effect|resource|browser|profile)$/.test(key), 'invalid-store-key');
    return path.join(root, 'records', `${key}.json`);
  };
  function loadGrant(id) {
    const values = config.grants.filter(grant => grant.execution_id === id);
    check(values.length === 1, 'independent-grant-required'); return values[0];
  }
  function profilePath(id) { return path.join(os.tmpdir(), `fkst-fixed-browser-${sha256(root + '\0' + id)}`); }
  function recover(id) {
    const resource = read(recordFile(`fixed-browser/${id}/resource`));
    const browser = read(recordFile(`fixed-browser/${id}/browser`));
    const profileOwner = read(recordFile(`fixed-browser/${id}/profile`));
    let browserLive = null;
    if (browser) {
      keys(browser, 'pid process_start_identity');
      check(Number.isInteger(browser.pid) && browser.pid > 0 && typeof browser.process_start_identity === 'string', 'resource-invalid');
      browserLive = store.processStartIdentity(browser.pid);
      if (browserLive !== null && browserLive !== browser.process_start_identity) return 'unknown';
    }
    if (resource) {
      keys(resource, 'pid process_start_identity');
      check(Number.isInteger(resource.pid) && resource.pid > 0 && typeof resource.process_start_identity === 'string', 'resource-invalid');
      const live = store.processStartIdentity(resource.pid);
      if (live !== null && live !== resource.process_start_identity) return 'unknown';
      const group = spawnSync('ps', ['-axo', 'pid=,pgid='], { encoding: 'utf8', timeout: 1000, maxBuffer: 1048576 });
      if (group.status !== 0) return 'unknown';
      const members = group.stdout.trim().split('\n').map(line => line.trim().split(/\s+/).map(Number))
        .filter(([, pgid]) => pgid === resource.pid).map(([pid]) => pid);
      if (members.length > 0) {
        // A stale group number is not authority. Require a live recorded member
        // with matching process start identity and actual group membership.
        const owned = (live !== null && members.includes(resource.pid))
          || (browserLive !== null && members.includes(browser.pid));
        if (owned) {
          try { process.kill(-resource.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') return 'unknown'; }
        }
        // Unverifiable groups may be Chrome children naturally exiting after
        // their parent. Wait for absence, but never signal or delete on a guess.
      }
      // Certify the dedicated worker group is gone, including Chrome children.
      const cleanupDeadline = Date.now() + 2000;
      while (true) {
        const processes = spawnSync('ps', ['-axo', 'pgid='], { encoding: 'utf8', timeout: Math.max(1, Math.min(1000, cleanupDeadline - Date.now())), maxBuffer: 1048576 });
        if (processes.status !== 0) return 'unknown';
        const alive = processes.stdout.trim().split(/\s+/).includes(String(resource.pid));
        if (!alive) break;
        if (Date.now() >= cleanupDeadline) return 'unknown';
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
      }
    }
    const profile = profilePath(id);
    if (fs.existsSync(profile)) {
      if (!profileOwner) return 'unknown';
      keys(profileOwner, 'device inode');
      const stat = fs.lstatSync(profile);
      if (stat.isSymbolicLink() || String(stat.dev) !== profileOwner.device || String(stat.ino) !== profileOwner.inode) return 'unknown';
      try { fs.rmSync(profile, { recursive: true }); } catch (_) { return 'unknown'; }
    }
    return 'complete';
  }
  return {
    policy: config.policy, loadGrant,
    now: () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    read: key => read(recordFile(key)),
    lock: (id, fn) => store.withLock(path.join(root, 'fixed-browser-locks', id), fn),
    immutable: (key, value) => {
      const response = operation({ operation: 'record-immutable', key, value });
      check(response.written || response.replayed, 'journal-conflict');
    },
    complete: (key, claim_id, completion) => {
      check(operation({ operation: 'replay-complete', key, claim_id, completion }).completed, 'completion-conflict');
    },
    readArtifact: logicalPath => {
      const artifact = read(path.join(root, 'artifacts', `${sha256(logicalPath)}.json`));
      check(artifact && artifact.path === logicalPath && sha256(artifact.body) === artifact.digest, 'artifact-digest-mismatch');
      return artifact.body;
    },
    writeArtifact: (logicalPath, body) => {
      check(operation({ operation: 'artifact-write', path: logicalPath, body }).written, 'artifact-conflict');
    },
    recover,
    browser: (plan, id) => {
      const profile = profilePath(id);
      check(!fs.existsSync(profile), 'profile-already-exists');
      const worker = path.resolve(__dirname, '../../../libraries/testing_runtime/bin/fkst-fixed-browser-worker.js');
      const response = spawnSync(process.execPath, [worker], {
        input: stable({ plan, policy: config.policy, chrome_path: config.chrome_path, profile, root, execution_id: id }),
        encoding: 'utf8', timeout: plan.timeout_ms + 6000, maxBuffer: 65536,
        detached: true, env: { PATH: process.env.PATH, TMPDIR: os.tmpdir(), HOME: os.tmpdir() },
      });
      if (response.status === 0 && !response.error) {
        try {
          const result = JSON.parse(response.stdout);
          keys(result, 'outcome observed_title target_status cleanup_status');
          result.cleanup_status = recover(id);
          return result;
        } catch (_) { /* Invalid worker output is never execution evidence. */ }
      }
      return { outcome: response.error && response.error.code === 'ETIMEDOUT' ? 'timeout' : 'error',
        observed_title: null, target_status: 'unresolved', cleanup_status: recover(id) };
    },
  };
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const options = {};
  check(args.length % 2 === 0, 'arguments-invalid');
  for (let i = 0; i < args.length; i += 2) {
    check(['--candidate', '--request', '--host-config'].includes(args[i]) && !options[args[i]], 'arguments-invalid');
    options[args[i]] = args[i + 1];
  }
  const config = read(options['--host-config']);
  const host = context(config);
  let result;
  if (command === 'compile') result = fixed.compile(read(options['--candidate']), host.policy);
  else {
    check(command === 'run' || command === 'validate-result', 'command-invalid');
    const request = read(options['--request']);
    result = command === 'run' ? fixed.run(request, host) : fixed.validate_result(request, host);
    const { validateCanonical } = await import('../../../libraries/testing_runtime/lib/fixed_browser_schema.mjs');
    await validateCanonical(result);
  }
  process.stdout.write(stable(result) + '\n');
}

if (require.main === module) main().catch(() => {
  // Errors can originate in Browser/JSON IO. Do not persist or echo raw state.
  process.stderr.write('fixed-browser: request, authority, execution or stored result invalid\n');
  process.exitCode = 1;
});
module.exports = { context };
