#!/usr/bin/env node

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

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

function wait(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function withLock(filePath, fn) {
  const lockPath = `${filePath}.lock`;
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  let fd;
  for (let attempt = 0; attempt < 250; attempt += 1) {
    try {
      fd = fs.openSync(lockPath, "wx", 0o600);
      fs.writeFileSync(fd, `${process.pid}\n`, "utf8");
      fs.fsyncSync(fd);
      break;
    } catch (error) {
      if (!error || error.code !== "EEXIST") throw error;
      let owner;
      try { owner = Number(fs.readFileSync(lockPath, "utf8").trim()); } catch (_ignored) {}
      if (!processAlive(owner)) {
        try { fs.unlinkSync(lockPath); } catch (_ignored) {}
        continue;
      }
      wait(20);
    }
  }
  if (fd === undefined) fail(`timed out acquiring ${lockPath}`);
  try {
    return fn();
  } finally {
    fs.closeSync(fd);
    try { fs.unlinkSync(lockPath); } catch (_ignored) {}
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

main();
