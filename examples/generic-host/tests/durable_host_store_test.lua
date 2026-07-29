local json_codec = require("testing_runtime.json")
local Store = require("host_durable_store")
local t = fkst.test

local function cleanup(path)
  os.execute("rm -rf " .. string.format("%q", path))
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if handle == nil then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_file(path, body)
  local parent = tostring(path):match("^(.*)/[^/]+$")
  if parent ~= nil then os.execute("mkdir -p " .. shell_quote(parent)) end
  local handle = assert(io.open(path, "wb"))
  handle:write(body)
  handle:close()
end

local function direct_exec(argv)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = os.tmpname() .. "-durable-store-stdout"
  local stderr_path = os.tmpname() .. "-durable-store-stderr"
  local ok, _, code = os.execute(table.concat(rendered, " ")
    .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local result = {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = read_file(stdout_path) or "",
    stderr = read_file(stderr_path) or "",
  }
  os.remove(stdout_path)
  os.remove(stderr_path)
  return result
end

local function runtime_cli()
  local candidates = {
    "examples/generic-host/bin/durable-host-store.js",
    "packages/generic-host/bin/durable-host-store.js",
  }
  for _, path in ipairs(candidates) do
    local handle = io.open(path, "rb")
    if handle ~= nil then handle:close() return path end
  end
  error("generic-host durable store test: runtime CLI is unavailable")
end

local function generic_runtime_cli()
  local candidates = {
    "examples/generic-host/bin/generic-host-runtime.js",
    "packages/generic-host/bin/generic-host-runtime.js",
  }
  for _, path in ipairs(candidates) do
    local handle = io.open(path, "rb")
    if handle ~= nil then handle:close() return path end
  end
  error("generic-host durable store test: generic runtime CLI is unavailable")
end

return {
  test_generic_host_runtime_echoes_exact_request_id_for_success_and_error = function()
    local root = os.tmpname() .. "-generic-host-runtime-correlation"
    cleanup(root)
    local request_path = root .. "/request.json"
    local response_path = root .. "/response.json"
    local error_response_path = root .. "/error-response.json"
    local ok, err = pcall(function()
      local request_id = "generic-host-correlation-success"
      write_file(request_path, json_codec.encode({ request_id = request_id, limit = 1 }) .. "\n")
      local result = direct_exec({
        "env", "FKST_DURABLE_ROOT=" .. root .. "/durable",
        "node", generic_runtime_cli(), "effect", "--name", "workflow-list-pending-runs",
        "--request", request_path, "--response", response_path,
      })
      t.eq(result.exit_code, 0)
      local response = json_codec.decode(assert(read_file(response_path)))
      t.eq(response.ok, true)
      t.eq(response.request_id, request_id)

      local error_request_id = "generic-host-correlation-error"
      write_file(request_path, json_codec.encode({ request_id = error_request_id }) .. "\n")
      result = direct_exec({
        "env", "FKST_DURABLE_ROOT=" .. root .. "/durable",
        "node", generic_runtime_cli(), "effect", "--name", "unknown-effect",
        "--request", request_path, "--response", error_response_path,
      })
      t.is_true(result.exit_code ~= 0)
      response = json_codec.decode(assert(read_file(error_response_path)))
      t.eq(response.ok, false)
      t.eq(response.request_id, error_request_id)
      t.is_true(type(response.error) == "string" and response.error:find("unknown effect", 1, true) ~= nil)
    end)
    cleanup(root)
    if not ok then error(err, 0) end
  end,

  test_durable_store_enforces_immutable_cas_claim_and_artifact_bindings = function()
    local root = os.tmpname() .. "-generic-host-durable-store"
    cleanup(root)
    local store = Store.new(root, runtime_cli())
    local ok, err = pcall(function()
      local first = store:immutable("workflow-qa/requests/run-1", { run_id = "run-1" })
      t.eq(first.written, true)
      t.eq(store:immutable("workflow-qa/requests/run-1", { run_id = "run-1" }).replayed, true)
      t.eq(store:immutable("workflow-qa/requests/run-1", { run_id = "run-2" }).replayed, false)

      local saved = store:cas("workflow-qa/state/run-1", { version = 1, phase = "pending" }, 0)
      t.eq(saved.saved, true)
      local stale = store:cas("workflow-qa/state/run-1", { version = 1, phase = "foreign" }, 0)
      t.eq(stale.saved, false)
      t.eq(stale.stale, true)
      t.eq(stale.version, 1)

      local claim = store:claim("testing-runner/replay/grant-1", {
        status = "claimed",
        claim_id = "claim-1",
        binding = { grant_id = "grant-1", trace_id = "trace-1" },
      })
      t.eq(claim.claimed, true)
      t.eq(claim.replayed, false)
      t.eq(store:claim("testing-runner/replay/grant-1", {
        status = "claimed",
        claim_id = "claim-1",
        binding = { grant_id = "grant-1", trace_id = "trace-1" },
      }).replayed, true)
      t.eq(store:claim("testing-runner/replay/grant-1", {
        status = "claimed",
        claim_id = "claim-2",
        binding = { grant_id = "grant-1", trace_id = "foreign" },
      }).claimed, false)

      local artifact = store:write_artifact(".testing/runs/run-1/execution.json", "{\"status\":\"passed\"}\n")
      t.eq(artifact.written, true)
      t.eq(#artifact.digest, 64)
      t.eq(store:read_artifact(".testing/runs/run-1/execution.json").digest, artifact.digest)
      t.eq(store:write_artifact(".testing/runs/run-1/execution.json", "changed\n").written, false)

      local complete = store:complete_replay("testing-runner/replay/grant-1", "claim-1", {
        result_ref = ".testing/runs/run-1/execution.json",
        result_sha256 = artifact.digest,
        trace_id = "trace-1",
      })
      t.eq(complete.completed, true)
      t.eq(complete.replayed, false)
      t.eq(store:complete_replay("testing-runner/replay/grant-1", "claim-1", {
        result_ref = ".testing/runs/run-1/execution.json",
        result_sha256 = artifact.digest,
        trace_id = "trace-1",
      }).replayed, true)
      t.eq(store:complete_replay("testing-runner/replay/grant-1", "foreign", {
        result_ref = ".testing/runs/run-1/execution.json",
        result_sha256 = artifact.digest,
      }).completed, false)
    end)
    cleanup(root)
    if not ok then error(err, 0) end
  end,

  test_durable_store_recovers_legacy_interim_and_crashed_reclaimer_locks = function()
    local root = os.tmpname() .. "-generic-host-durable-lock-recovery"
    cleanup(root)
    local script_path = root .. "/lock-recovery.js"
    write_file(script_path, [[
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const storePath = path.resolve(process.argv[2]);
const root = path.resolve(process.argv[3]);
const store = require(storePath);
const deadPid = 2147483647;
const interimOwner = {
  schema: 'generic-host.durable-lock-owner.v1',
  pid: deadPid,
  process_start_identity: 'stale-owner',
  token: 'a'.repeat(32),
};
const interimReclaimer = {
  schema: 'generic-host.durable-lock-reclaim.v1',
  pid: deadPid,
  process_start_identity: 'stale-reclaimer',
  token: 'b'.repeat(32),
  observed: { device: 'old-device', inode: 'old-inode', token: 'a'.repeat(32) },
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function exercise(label, setup) {
  const target = path.join(root, 'records', label, 'record.json');
  const lockPath = `${target}.lock`;
  const ownerPath = `${lockPath}.v2`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  setup(lockPath, ownerPath);
  store.withLock(target, () => {
    const legacy = store.observeLegacyLock(lockPath);
    assert(legacy && !legacy.malformed && legacy.kind === 'legacy-pid', `${label}: legacy lock is not a PID`);
    assert(legacy.pid === process.pid, `${label}: legacy lock PID differs`);
    assert(fs.readFileSync(lockPath, 'utf8') === `${process.pid}\n`, `${label}: legacy lock is not decimal`);
    const owner = store.observeOwner(ownerPath, 'generic-host.durable-lock-owner.v2');
    assert(owner && !owner.malformed && owner.owner, `${label}: v2 owner is unavailable`);
    assert(owner.owner.pid === process.pid, `${label}: v2 owner PID differs`);
    assert(owner.owner.observations.legacy_lock.device === legacy.device,
      `${label}: v2 owner device observation differs`);
    assert(owner.owner.observations.legacy_lock.inode === legacy.inode,
      `${label}: v2 owner inode observation differs`);
    assert(owner.owner.observations.legacy_lock.pid === legacy.pid,
      `${label}: v2 owner PID observation differs`);
  });
  for (const suffix of ['', '.reclaim', '.v2', '.v2.reclaim']) {
    assert(!fs.existsSync(`${lockPath}${suffix}`), `${label}: lock artifact remained: ${suffix || 'legacy'}`);
  }
}

exercise('dead-legacy-pid', (lockPath) => {
  fs.writeFileSync(lockPath, `${deadPid}\n`);
});
exercise('interim-json-owner', (lockPath) => {
  fs.writeFileSync(lockPath, `${JSON.stringify(interimOwner)}\n`);
});
exercise('crashed-hard-link-reclaimer', (lockPath) => {
  fs.writeFileSync(lockPath, `${deadPid}\n`);
  fs.linkSync(lockPath, `${lockPath}.reclaim`);
});
exercise('stale-interim-reclaimer', (lockPath) => {
  fs.writeFileSync(lockPath, `${deadPid}\n`);
  fs.writeFileSync(`${lockPath}.reclaim`, `${JSON.stringify(interimReclaimer)}\n`);
});

function exerciseInjectedReplacement() {
  const target = path.join(root, 'records', 'injected-successor', 'record.json');
  const lockPath = `${target}.lock`;
  const ownerPath = `${lockPath}.v2`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const originalRename = fs.renameSync;
  const originalUnlink = fs.unlinkSync;
  let acquiredLegacy;
  let injected = false;
  let canonicalUnlinkAttempted = false;
  try {
    store.withLock(target, () => {
      acquiredLegacy = store.observeLegacyLock(lockPath);
      fs.unlinkSync = function(candidate, ...args) {
        if (candidate === lockPath) canonicalUnlinkAttempted = true;
        return originalUnlink.call(fs, candidate, ...args);
      };
      fs.renameSync = function(source, destination, ...args) {
        if (source === lockPath && !injected) {
          injected = true;
          originalUnlink.call(fs, lockPath);
          fs.writeFileSync(lockPath, `${process.pid}\n`);
        }
        return originalRename.call(fs, source, destination, ...args);
      };
    });
  } finally {
    fs.renameSync = originalRename;
    fs.unlinkSync = originalUnlink;
  }
  assert(injected, 'injected successor hook was not exercised');
  assert(!canonicalUnlinkAttempted, 'canonical legacy pathname was passed to unlinkSync');
  const successor = store.observeLegacyLock(lockPath);
  assert(successor && !successor.malformed && successor.kind === 'legacy-pid',
    'injected successor was not restored');
  assert(successor.inode !== acquiredLegacy.inode, 'injected successor did not replace the observed inode');
  assert(!fs.existsSync(ownerPath), 'v2 owner remained after injected successor release');
  assert(!fs.existsSync(`${lockPath}.reclaim`), 'legacy fence remained after injected successor release');
  originalUnlink.call(fs, lockPath);
}

function exerciseCrashBetweenReleases() {
  const target = path.join(root, 'records', 'release-crash', 'record.json');
  const lockPath = `${target}.lock`;
  const ownerPath = `${lockPath}.v2`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const worker = `
    const fs=require('node:fs'),path=require('node:path');
    const store=require(path.resolve(process.argv[1]));
    const target=path.resolve(process.argv[2]);
    const ownerPath=target+'.lock.v2';
    const rename=fs.renameSync;
    fs.renameSync=function(source,destination,...args) {
      if (source===ownerPath) process.exit(73);
      return rename.call(fs,source,destination,...args);
    };
    store.withLock(target,()=>{});
    process.exit(74);
  `;
  const crashed = spawnSync(process.execPath, ['-e', worker, storePath, target], { encoding: 'utf8' });
  assert(crashed.status === 73, `release crash hook was not exercised: ${JSON.stringify(crashed)}`);
  assert(!fs.existsSync(lockPath), 'legacy lock remained after crash before v2 release');
  assert(fs.existsSync(ownerPath), 'v2 identity was removed before the legacy lock');
  assert(fs.existsSync(`${ownerPath}.reclaim`), 'v2 release fence was not left by simulated crash');
  store.withLock(target, () => {});
  for (const candidate of [lockPath, ownerPath, `${lockPath}.reclaim`, `${ownerPath}.reclaim`]) {
    assert(!fs.existsSync(candidate), `release crash recovery left ${candidate}`);
  }
}

function expectImmediateCorruption(label, setup) {
  const target = path.join(root, 'records', 'corrupt', label, 'record.json');
  const lockPath = `${target}.lock`;
  const ownerPath = `${lockPath}.v2`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  setup(lockPath, ownerPath);
  const started = Date.now();
  let caught;
  try {
    store.withLock(target, () => {});
  } catch (error) {
    caught = error;
  }
  assert(caught && /malformed; manual recovery required/.test(String(caught.message || caught)),
    `${label}: corruption did not fail with manual recovery guidance: ${caught}`);
  assert(Date.now() - started < 2000, `${label}: corruption spent the acquisition timeout`);
}

exerciseInjectedReplacement();
exerciseCrashBetweenReleases();
expectImmediateCorruption('empty-legacy', (lockPath) => fs.writeFileSync(lockPath, ''));
expectImmediateCorruption('partial-legacy', (lockPath) => fs.writeFileSync(lockPath, '{'));
expectImmediateCorruption('empty-v2', (_lockPath, ownerPath) => fs.writeFileSync(ownerPath, ''));
expectImmediateCorruption('partial-v2', (_lockPath, ownerPath) => fs.writeFileSync(ownerPath, '{'));
expectImmediateCorruption('empty-fence', (lockPath) => {
  fs.writeFileSync(lockPath, `${deadPid}\n`);
  fs.writeFileSync(`${lockPath}.reclaim`, '');
});
expectImmediateCorruption('partial-fence', (lockPath) => {
  fs.writeFileSync(lockPath, `${deadPid}\n`);
  fs.writeFileSync(`${lockPath}.reclaim`, '{');
});
]])
    local result = direct_exec({ "node", script_path, runtime_cli(), root })
    cleanup(root)
    if result.exit_code ~= 0 then
      error("generic-host durable lock recovery failed\nstdout=" .. result.stdout .. "\nstderr=" .. result.stderr)
    end
  end,

  test_durable_store_stale_observer_cannot_unlink_successor_lock = function()
    local root = os.tmpname() .. "-generic-host-durable-lock-race"
    cleanup(root)
    local script_path = root .. "/lock-race.js"
    write_file(script_path, [[
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const storePath = path.resolve(process.argv[2]);
const root = path.resolve(process.argv[3]);
const store = require(storePath);
const target = path.join(root, 'records', 'workflow-qa', 'state', 'run-1.json');
const lockPath = `${target}.lock`;
const ownerPath = `${lockPath}.v2`;
const aReady = path.join(root, 'a-stale-ready.json');
const aContinue = path.join(root, 'a-stale-continue');
const aRecheck = path.join(root, 'a-recheck-ready.json');
const aDone = path.join(root, 'a-done');
const bReady = path.join(root, 'b-acquired-ready.json');
const bContinue = path.join(root, 'b-acquired-continue');
const bDone = path.join(root, 'b-done');
const worker = `
  const fs=require('node:fs'),path=require('node:path');
  const store=require(path.resolve(process.argv[1]));
  store.withLock(process.argv[2],()=>fs.writeFileSync(process.argv[3],String(process.pid)));
`;

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitFor(filePath, child, label) {
  const deadline = Date.now() + 10000;
  while (!fs.existsSync(filePath)) {
    if (child && child.exitCode !== null) throw new Error(`${label} exited before ${filePath}`);
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${filePath}`);
    await delay(10);
  }
}

function exitOf(child, label) {
  return new Promise((resolve, reject) => child.once('exit', (code, signal) => {
    if (code === 0) resolve();
    else reject(new Error(`${label} exited code=${code} signal=${signal}`));
  }));
}

function assertCompleteOwner(observed, legacy, label) {
  if (!observed || observed.malformed || !observed.owner
    || observed.owner.schema !== 'generic-host.durable-lock-owner.v2'
    || !/^[0-9a-f]{32}$/.test(observed.owner.token)
    || typeof observed.device !== 'string' || typeof observed.inode !== 'string'
    || !observed.owner.observations || !observed.owner.observations.legacy_lock
    || observed.owner.observations.legacy_lock.device !== legacy.device
    || observed.owner.observations.legacy_lock.inode !== legacy.inode
    || observed.owner.observations.legacy_lock.pid !== legacy.pid) {
    throw new Error(`${label} owner observation is incomplete: ${JSON.stringify(observed)}`);
  }
}

fs.mkdirSync(path.dirname(lockPath), { recursive: true });
fs.writeFileSync(lockPath, `${JSON.stringify({
  schema: 'generic-host.durable-lock-owner.v1',
  pid: 2147483647,
  process_start_identity: 'stale-owner',
  token: 'a'.repeat(32),
})}\n`);

let contenderA;
let contenderB;
(async () => {
  try {
    contenderA = spawn(process.execPath, ['-e', worker, storePath, target, aDone], {
      env: { ...process.env,
        FKST_DURABLE_STORE_TEST_STALE_READY: aReady,
        FKST_DURABLE_STORE_TEST_STALE_CONTINUE: aContinue,
        FKST_DURABLE_STORE_TEST_RECHECK_READY: aRecheck },
      stdio: 'inherit',
    });
    const aExit = exitOf(contenderA, 'contender A');
    aExit.catch(() => {});
    await waitFor(aReady, contenderA, 'contender A');

    contenderB = spawn(process.execPath, ['-e', worker, storePath, target, bDone], {
      env: { ...process.env,
        FKST_DURABLE_STORE_TEST_ACQUIRED_READY: bReady,
        FKST_DURABLE_STORE_TEST_ACQUIRED_CONTINUE: bContinue },
      stdio: 'inherit',
    });
    const bExit = exitOf(contenderB, 'contender B');
    bExit.catch(() => {});
    await waitFor(bReady, contenderB, 'contender B');

    const beforeLegacy = store.observeLegacyLock(lockPath);
    if (!beforeLegacy || beforeLegacy.malformed || beforeLegacy.kind !== 'legacy-pid') {
      throw new Error(`successor legacy observation is incomplete: ${JSON.stringify(beforeLegacy)}`);
    }
    const beforeOwner = store.observeOwner(ownerPath, 'generic-host.durable-lock-owner.v2');
    assertCompleteOwner(beforeOwner, beforeLegacy, 'successor');
    const readyOwner = JSON.parse(fs.readFileSync(bReady, 'utf8'));
    if (readyOwner.owner_token !== beforeOwner.owner.token) {
      throw new Error('successor token differs from acquired witness');
    }
    for (let index = 0; index < 100; index += 1) {
      const publishedLegacy = store.observeLegacyLock(lockPath);
      if (!publishedLegacy || publishedLegacy.malformed
        || publishedLegacy.device !== beforeLegacy.device || publishedLegacy.inode !== beforeLegacy.inode
        || publishedLegacy.pid !== beforeLegacy.pid) {
        throw new Error(`published legacy lock changed: ${JSON.stringify(publishedLegacy)}`);
      }
      assertCompleteOwner(store.observeOwner(ownerPath, 'generic-host.durable-lock-owner.v2'),
        publishedLegacy, 'published');
    }

    fs.writeFileSync(aContinue, 'continue\n');
    await waitFor(aRecheck, contenderA, 'contender A stale recheck');
    if (fs.existsSync(aDone)) throw new Error('stale contender acquired while successor still owned the lock');
    const recheck = JSON.parse(fs.readFileSync(aRecheck, 'utf8'));
    if (recheck.owner_token !== null
      || recheck.device !== beforeLegacy.device || recheck.inode !== beforeLegacy.inode) {
      throw new Error(`stale contender rechecked a different successor: ${JSON.stringify(recheck)}`);
    }
    const afterLegacy = store.observeLegacyLock(lockPath);
    const afterOwner = store.observeOwner(ownerPath, 'generic-host.durable-lock-owner.v2');
    assertCompleteOwner(afterOwner, afterLegacy, 'preserved successor');
    if (beforeLegacy.device !== afterLegacy.device || beforeLegacy.inode !== afterLegacy.inode
      || beforeLegacy.pid !== afterLegacy.pid || beforeOwner.device !== afterOwner.device
      || beforeOwner.inode !== afterOwner.inode || beforeOwner.owner.token !== afterOwner.owner.token) {
      throw new Error('stale contender replaced or unlinked the successor lock');
    }

    fs.writeFileSync(bContinue, 'continue\n');
    await waitFor(bDone, contenderB, 'contender B');
    await waitFor(aDone, contenderA, 'contender A');
    await Promise.all([aExit, bExit]);
    for (const candidate of [lockPath, ownerPath, `${lockPath}.reclaim`, `${ownerPath}.reclaim`]) {
      if (fs.existsSync(candidate)) throw new Error(`lock remained after both contenders completed: ${candidate}`);
    }
  } catch (error) {
    if (contenderA && contenderA.exitCode === null) contenderA.kill('SIGKILL');
    if (contenderB && contenderB.exitCode === null) contenderB.kill('SIGKILL');
    throw error;
  }
})().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
]])
    local result = direct_exec({ "node", script_path, runtime_cli(), root })
    cleanup(root)
    if result.exit_code ~= 0 then
      error("generic-host durable lock race failed\nstdout=" .. result.stdout .. "\nstderr=" .. result.stderr)
    end
  end,
}
