#!/usr/bin/env node

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function fail(message) {
  throw new Error(`generic-host durable store: ${message}`);
}

function stable(value) {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
}

function equal(left, right) {
  return stable(left) === stable(right);
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function validateRoot(root) {
  if (typeof root !== "string" || !path.isAbsolute(root)) fail("root must be absolute");
  return path.resolve(root);
}

function validateKey(key) {
  if (typeof key !== "string" || key.length === 0 || key.length > 1024) fail("record key is invalid");
  const parts = key.split("/");
  if (parts.some((part) => !/^[A-Za-z0-9._-]{1,180}$/.test(part) || part === "." || part === "..")) {
    fail("record key contains an unsafe segment");
  }
  return parts;
}

function recordPath(root, key) {
  return path.join(root, "records", ...validateKey(key)) + ".json";
}

function artifactPath(root, logicalPath) {
  if (typeof logicalPath !== "string" || !logicalPath.startsWith(".testing/runs/")
      || logicalPath.includes("\0") || logicalPath.split("/").includes("..")) {
    fail("artifact path must stay under .testing/runs");
  }
  return path.join(root, "artifacts", `${sha256(logicalPath)}.json`);
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    if (error && error.code === "ENOENT") return undefined;
    throw error;
  }
}

function syncDirectory(directory) {
  const fd = fs.openSync(directory, "r");
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function atomicWrite(filePath, value) {
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.tmp-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(fd, `${stable(value)}\n`, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, filePath);
  syncDirectory(directory);
}

function processAlive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error && error.code === "EPERM";
  }
}

function processStartIdentity(pid) {
  if (!Number.isInteger(pid) || pid < 1) return null;
  const result = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], {
    shell: false,
    encoding: "utf8",
    timeout: 1000,
    maxBuffer: 1024,
  });
  const identity = result.status === 0 ? String(result.stdout || "").trim() : "";
  return identity || null;
}

function wait(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

const INTERIM_OWNER_SCHEMA = "generic-host.durable-lock-owner.v1";
const OWNER_SCHEMA = "generic-host.durable-lock-owner.v2";
const INTERIM_RECLAIM_SCHEMA = "generic-host.durable-lock-reclaim.v1";

function validOwner(owner, schema) {
  const valid = Boolean(owner && owner.schema === schema && Number.isInteger(owner.pid) && owner.pid > 0
    && typeof owner.process_start_identity === "string" && owner.process_start_identity !== ""
    && typeof owner.token === "string" && /^[0-9a-f]{32}$/.test(owner.token));
  if (!valid || schema !== OWNER_SCHEMA) return valid;
  const legacy = owner.observations && owner.observations.legacy_lock;
  return Boolean(legacy && typeof legacy.device === "string" && typeof legacy.inode === "string"
    && Number.isInteger(legacy.pid) && legacy.pid > 0);
}

function observeFile(filePath) {
  let fd;
  try {
    fd = fs.openSync(filePath, "r");
    const stat = fs.fstatSync(fd);
    const body = fs.readFileSync(fd, "utf8");
    return { body, device: String(stat.dev), inode: String(stat.ino) };
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    return { malformed: true };
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function parseOwnerObservation(observed, schema) {
  if (!observed || observed.malformed) return observed;
  try {
    const owner = JSON.parse(observed.body);
    if (!validOwner(owner, schema)) return { ...observed, malformed: true };
    return { ...observed, owner };
  } catch (_error) {
    return { ...observed, malformed: true };
  }
}

function observeOwner(ownerPath, schema) {
  return parseOwnerObservation(observeFile(ownerPath), schema);
}

function parseLegacyObservation(observed) {
  if (!observed || observed.malformed) return observed;
  const body = observed.body.trim();
  if (/^[1-9][0-9]*$/.test(body)) {
    const pid = Number(body);
    if (Number.isSafeInteger(pid)) return { ...observed, kind: "legacy-pid", pid };
  }
  const interim = parseOwnerObservation(observed, INTERIM_OWNER_SCHEMA);
  if (interim && !interim.malformed) return { ...interim, kind: "interim-owner" };
  return { ...observed, kind: "unknown", malformed: true };
}

function observeLegacyLock(lockPath) {
  return parseLegacyObservation(observeFile(lockPath));
}

function sameFileObservation(left, right) {
  return Boolean(left && right && !left.malformed && !right.malformed
    && left.device === right.device && left.inode === right.inode && left.body === right.body);
}

function sameOwnerObservation(left, right) {
  return Boolean(sameFileObservation(left, right) && left.owner && right.owner
    && left.owner.token === right.owner.token);
}

function ownerIsStale(observed) {
  const owner = observed && observed.owner;
  if (!owner) return false;
  if (!processAlive(owner.pid)) return true;
  const current = processStartIdentity(owner.pid);
  return current !== null && current !== owner.process_start_identity;
}

function ownerObservesLegacy(owner, legacy) {
  const observed = owner && owner.observations && owner.observations.legacy_lock;
  return Boolean(observed && legacy && legacy.kind === "legacy-pid"
    && observed.device === legacy.device && observed.inode === legacy.inode && observed.pid === legacy.pid);
}

function legacyOwnerIsStale(observed, ownerPath) {
  if (!observed || observed.malformed) return false;
  if (observed.kind === "interim-owner") return ownerIsStale(observed);
  if (observed.kind !== "legacy-pid") return false;
  if (!processAlive(observed.pid)) return true;
  const owner = observeOwner(ownerPath, OWNER_SCHEMA);
  if (!owner || owner.malformed || !ownerObservesLegacy(owner.owner, observed)) return false;
  const current = processStartIdentity(observed.pid);
  return current !== null && current !== owner.owner.process_start_identity;
}

function publishOwner(ownerPath, owner) {
  const directory = path.dirname(ownerPath);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = `${ownerPath}.owner-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(fd, `${stable(owner)}\n`, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.linkSync(temporary, ownerPath);
    syncDirectory(directory);
    return observeOwner(ownerPath, owner.schema);
  } catch (error) {
    if (!error || error.code !== "EEXIST") throw error;
    return null;
  } finally {
    try { fs.unlinkSync(temporary); } catch (_ignored) {}
  }
}

function releaseOwner(ownerPath, owner, acquired) {
  const current = observeOwner(ownerPath, owner.schema);
  if (!sameOwnerObservation(current, acquired) || current.owner.token !== owner.token) return false;
  const fencePath = `${ownerPath}.reclaim`;
  const fence = snapshotFence(ownerPath, acquired, (target) => observeOwner(target, owner.schema));
  if (!fence) return false;
  try {
    return retireObservedPath(ownerPath, acquired);
  } finally {
    retireObservedPath(fencePath, fence);
  }
}

function publishLegacyLock(lockPath) {
  const directory = path.dirname(lockPath);
  const temporary = `${lockPath}.legacy-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(fd, `${process.pid}\n`, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.linkSync(temporary, lockPath);
    syncDirectory(directory);
    const acquired = observeLegacyLock(lockPath);
    return acquired && acquired.kind === "legacy-pid" && acquired.pid === process.pid ? acquired : null;
  } catch (error) {
    if (!error || error.code !== "EEXIST") throw error;
    return null;
  } finally {
    try { fs.unlinkSync(temporary); } catch (_ignored) {}
  }
}

function retireObservedPath(filePath, observed) {
  const directory = path.dirname(filePath);
  const quarantine = `${filePath}.retired-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  try {
    fs.renameSync(filePath, quarantine);
    syncDirectory(directory);
  } catch (error) {
    if (error && error.code === "ENOENT") return false;
    throw error;
  }

  const moved = observeFile(quarantine);
  if (!sameFileObservation(moved, observed)) {
    try {
      fs.linkSync(quarantine, filePath);
      syncDirectory(directory);
    } catch (error) {
      if (error && error.code === "EEXIST") {
        fail(`lock path changed while restoring ${filePath}; displaced entry retained at ${quarantine}`);
      }
      throw error;
    }
    const restored = observeFile(filePath);
    if (!sameFileObservation(restored, moved)) {
      fail(`lock replacement could not be restored at ${filePath}; displaced entry retained at ${quarantine}`);
    }
    fs.unlinkSync(quarantine);
    syncDirectory(directory);
    return false;
  }

  fs.unlinkSync(quarantine);
  syncDirectory(directory);
  return true;
}

function snapshotFence(filePath, observed, observeLock) {
  const fencePath = `${filePath}.reclaim`;
  try {
    fs.linkSync(filePath, fencePath);
    syncDirectory(path.dirname(filePath));
  } catch (error) {
    if (error && (error.code === "EEXIST" || error.code === "ENOENT")) return null;
    throw error;
  }
  const fence = observeLock(fencePath);
  if (sameFileObservation(fence, observed)) return fence;
  if (fence) retireObservedPath(fencePath, fence);
  return null;
}

function releaseLegacyLock(lockPath, acquired) {
  const current = observeLegacyLock(lockPath);
  if (!sameFileObservation(current, acquired) || current.kind !== "legacy-pid" || current.pid !== process.pid) {
    return false;
  }
  const fencePath = `${lockPath}.reclaim`;
  const fence = snapshotFence(lockPath, acquired, observeLegacyLock);
  if (!fence) return false;
  try {
    return retireObservedPath(lockPath, acquired);
  } finally {
    retireObservedPath(fencePath, fence);
  }
}

function pauseTestHook(prefix, lockPath, owner) {
  const readyPath = process.env[`${prefix}_READY`];
  const continuePath = process.env[`${prefix}_CONTINUE`];
  if (!readyPath || !continuePath) return;
  atomicWrite(readyPath, { lock_path: lockPath, owner_token: owner && owner.token || null });
  while (!fs.existsSync(continuePath)) wait(10);
}

function writeTestWitness(prefix, lockPath, observed) {
  const readyPath = process.env[`${prefix}_READY`];
  if (!readyPath) return;
  atomicWrite(readyPath, {
    lock_path: lockPath,
    owner_token: observed && observed.owner && observed.owner.token || null,
    device: observed && observed.device || null,
    inode: observed && observed.inode || null,
  });
}

function corruptLockArtifact(filePath) {
  fail(`lock artifact ${filePath} is malformed; manual recovery required`);
}

function recoverReclaimFence(lockPath, observeLock, isStale) {
  const fencePath = `${lockPath}.reclaim`;
  const fenceFile = observeFile(fencePath);
  if (!fenceFile) return true;
  if (fenceFile.malformed) corruptLockArtifact(fencePath);

  const interim = parseOwnerObservation(fenceFile, INTERIM_RECLAIM_SCHEMA);
  if (interim && !interim.malformed) {
    if (!ownerIsStale(interim)) return false;
    return retireObservedPath(fencePath, fenceFile);
  }

  const fence = observeLock(fencePath);
  if (!fence || fence.malformed) corruptLockArtifact(fencePath);
  const current = observeLock(lockPath);
  if (current && current.malformed) corruptLockArtifact(lockPath);
  if (!current) return retireObservedPath(fencePath, fence);
  if (!sameFileObservation(current, fence)) return retireObservedPath(fencePath, fence);
  if (!isStale(current)) return false;

  const confirmedFence = observeLock(fencePath);
  const confirmedCurrent = observeLock(lockPath);
  if ((confirmedFence && confirmedFence.malformed) || (confirmedCurrent && confirmedCurrent.malformed)) {
    corruptLockArtifact(confirmedFence && confirmedFence.malformed ? fencePath : lockPath);
  }
  if (!sameFileObservation(confirmedFence, fence) || !sameFileObservation(confirmedCurrent, current)
      || !isStale(confirmedCurrent)) return false;
  const retired = retireObservedPath(lockPath, confirmedCurrent);
  retireObservedPath(fencePath, confirmedFence);
  return retired;
}

function reclaimStaleLock(lockPath, observed, observeLock, isStale, useTestHooks) {
  if (useTestHooks) pauseTestHook("FKST_DURABLE_STORE_TEST_STALE", lockPath, observed.owner);
  if (!recoverReclaimFence(lockPath, observeLock, isStale)) return false;
  const fencePath = `${lockPath}.reclaim`;
  const fence = snapshotFence(lockPath, observed, observeLock);
  if (!fence) {
    if (useTestHooks) writeTestWitness("FKST_DURABLE_STORE_TEST_RECHECK", lockPath, observeLock(lockPath));
    return false;
  }
  try {
    const current = observeLock(lockPath);
    if (current && current.malformed) corruptLockArtifact(lockPath);
    if (!sameFileObservation(current, observed) || !isStale(current)) {
      if (useTestHooks) writeTestWitness("FKST_DURABLE_STORE_TEST_RECHECK", lockPath, current);
      return false;
    }
    if (!retireObservedPath(lockPath, current)) {
      const successor = observeLock(lockPath);
      if (useTestHooks) writeTestWitness("FKST_DURABLE_STORE_TEST_RECHECK", lockPath, successor);
      return false;
    }
    return true;
  } finally {
    retireObservedPath(fencePath, fence);
  }
}

function acquireLegacyLock(lockPath, ownerPath) {
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (!recoverReclaimFence(lockPath, observeLegacyLock,
      (current) => legacyOwnerIsStale(current, ownerPath))) {
      wait(20);
      continue;
    }
    const acquired = publishLegacyLock(lockPath);
    if (acquired) return acquired;
    const observed = observeLegacyLock(lockPath);
    if (observed && observed.malformed) corruptLockArtifact(lockPath);
    if (observed && legacyOwnerIsStale(observed, ownerPath)) {
      reclaimStaleLock(lockPath, observed, observeLegacyLock,
        (current) => legacyOwnerIsStale(current, ownerPath), true);
      continue;
    }
    wait(20);
  }
  return null;
}

function acquireOwnerLock(ownerPath, owner) {
  for (let attempt = 0; attempt < 500; attempt += 1) {
    if (!recoverReclaimFence(ownerPath, (target) => observeOwner(target, OWNER_SCHEMA), ownerIsStale)) {
      wait(20);
      continue;
    }
    const acquired = publishOwner(ownerPath, owner);
    if (acquired) return acquired;
    const observed = observeOwner(ownerPath, OWNER_SCHEMA);
    if (observed && observed.malformed) corruptLockArtifact(ownerPath);
    if (observed && observed.owner && ownerIsStale(observed)) {
      reclaimStaleLock(ownerPath, observed, (target) => observeOwner(target, OWNER_SCHEMA), ownerIsStale, false);
      continue;
    }
    wait(20);
  }
  return null;
}

function withLock(filePath, fn) {
  const lockPath = `${filePath}.lock`;
  const ownerPath = `${lockPath}.v2`;
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const identity = processStartIdentity(process.pid);
  if (identity === null) fail("lock owner identity is unavailable");
  const acquiredLegacy = acquireLegacyLock(lockPath, ownerPath);
  if (!acquiredLegacy) fail(`timed out acquiring ${lockPath}`);
  const owner = {
    schema: OWNER_SCHEMA,
    pid: process.pid,
    process_start_identity: identity,
    token: crypto.randomBytes(16).toString("hex"),
    observations: {
      legacy_lock: {
        device: acquiredLegacy.device,
        inode: acquiredLegacy.inode,
        pid: acquiredLegacy.pid,
      },
    },
  };
  let acquiredOwner;
  try {
    acquiredOwner = acquireOwnerLock(ownerPath, owner);
    if (!acquiredOwner) fail(`timed out acquiring ${ownerPath}`);
    pauseTestHook("FKST_DURABLE_STORE_TEST_ACQUIRED", ownerPath, owner);
    return fn();
  } finally {
    let cleanupError;
    try {
      releaseLegacyLock(lockPath, acquiredLegacy);
    } catch (error) {
      cleanupError = error;
    }
    try {
      if (acquiredOwner) releaseOwner(ownerPath, owner, acquiredOwner);
    } catch (error) {
      if (!cleanupError) cleanupError = error;
    }
    if (cleanupError) throw cleanupError;
  }
}

function listRecords(root, prefix) {
  const prefixParts = validateKey(prefix);
  const base = path.join(root, "records", ...prefixParts);
  const entries = [];
  function visit(directory) {
    if (!fs.existsSync(directory)) return;
    for (const item of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const target = path.join(directory, item.name);
      if (item.isDirectory()) visit(target);
      if (!item.isFile() || !item.name.endsWith(".json")) continue;
      const relative = path.relative(path.join(root, "records"), target).split(path.sep).join("/");
      entries.push({ key: relative.slice(0, -5), value: readJson(target) });
    }
  }
  if (fs.existsSync(`${base}.json`)) {
    entries.push({ key: prefix, value: readJson(`${base}.json`) });
  }
  visit(base);
  return entries;
}

function execute(request) {
  const root = validateRoot(request.root);
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  switch (request.operation) {
    case "digest":
      return { digest: sha256(String(request.body || "")) };
    case "record-read": {
      const value = readJson(recordPath(root, request.key));
      return { found: value !== undefined, value };
    }
    case "record-list":
      return { entries: listRecords(root, request.prefix) };
    case "record-immutable": {
      const target = recordPath(root, request.key);
      return withLock(target, () => {
        const current = readJson(target);
        if (current !== undefined) return { written: false, replayed: equal(current, request.value), value: current };
        atomicWrite(target, request.value);
        return { written: true, replayed: false, value: request.value };
      });
    }
    case "record-cas": {
      const target = recordPath(root, request.key);
      return withLock(target, () => {
        const current = readJson(target);
        const currentVersion = current === undefined ? 0 : Number(current.version);
        if (!Number.isInteger(currentVersion)) fail("CAS record has no integer version");
        if (currentVersion !== request.expected_version) {
          return { saved: false, stale: true, version: currentVersion, value: current };
        }
        if (!request.value || request.value.version !== request.expected_version + 1) {
          fail("CAS value version must advance by one");
        }
        atomicWrite(target, request.value);
        return { saved: true, stale: false, version: request.value.version, value: request.value };
      });
    }
    case "record-claim": {
      const target = recordPath(root, request.key);
      return withLock(target, () => {
        const current = readJson(target);
        if (current !== undefined) {
          return { claimed: equal(current.binding, request.value.binding), replayed: true, value: current };
        }
        atomicWrite(target, request.value);
        return { claimed: true, replayed: false, value: request.value };
      });
    }
    case "replay-complete": {
      const target = recordPath(root, request.key);
      return withLock(target, () => {
        const current = readJson(target);
        if (!current || current.claim_id !== request.claim_id) return { completed: false, reason: "claim-mismatch" };
        if (current.status === "completed") {
          return { completed: equal(current.completion, request.completion), replayed: true, value: current };
        }
        if (current.status !== "claimed") return { completed: false, reason: "claim-not-active" };
        const value = { ...current, status: "completed", completion: request.completion,
          result_ref: request.completion.result_ref, result_sha256: request.completion.result_sha256 };
        atomicWrite(target, value);
        return { completed: true, replayed: false, value };
      });
    }
    case "artifact-read": {
      const value = readJson(artifactPath(root, request.path));
      if (value === undefined) return { found: false };
      if (value.path !== request.path || sha256(value.body) !== value.digest) fail("artifact index binding differs");
      return { found: true, body: value.body, digest: value.digest };
    }
    case "artifact-write": {
      const target = artifactPath(root, request.path);
      const value = { path: request.path, digest: sha256(request.body), body: request.body };
      return withLock(target, () => {
        const current = readJson(target);
        if (current !== undefined) {
          return { written: current.path === value.path && current.body === value.body,
            replayed: true, digest: current.digest };
        }
        atomicWrite(target, value);
        return { written: true, replayed: false, digest: value.digest };
      });
    }
    default:
      fail(`unknown operation ${request.operation}`);
  }
}

function main() {
  const requestIndex = process.argv.indexOf("--request");
  const responseIndex = process.argv.indexOf("--response");
  if (requestIndex < 0 || responseIndex < 0) fail("--request and --response are required");
  const requestPath = process.argv[requestIndex + 1];
  const responsePath = process.argv[responseIndex + 1];
  try {
    const result = execute(JSON.parse(fs.readFileSync(requestPath, "utf8")));
    atomicWrite(responsePath, { ok: true, result });
  } catch (error) {
    atomicWrite(responsePath, { ok: false, error: String(error && error.message || error) });
    process.exitCode = 1;
  }
}

if (require.main === module) main();

module.exports = { execute, observeLegacyLock, observeOwner, processStartIdentity, stable, withLock };
