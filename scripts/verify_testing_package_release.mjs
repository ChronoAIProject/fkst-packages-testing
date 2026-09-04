#!/usr/bin/env node
import { createHash, createPublicKey, verify as verifySignature } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PAYLOAD_TYPE = "application/vnd.in-toto+json";
const STATEMENT_TYPE = "https://in-toto.io/Statement/v1";
const PREDICATE_TYPE = "https://chronoaiproject.github.io/fkst-packages-testing/attestations/testing-package-release/v1";
const SUBJECT_NAME = "package-release/testing-package-release.v1.json";
const KEY_ID = "fkst-packages-testing-release-v1-2026-09-04";
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const HEX_64 = /^[0-9a-f]{64}$/;
const HEX_40 = /^[0-9a-f]{40}$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function fail(message) { throw new Error(message); }
function sha256(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function object(value, field) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) fail(`${field} must be an object`);
  return value;
}
function closed(value, fields, field) {
  const actual = Object.keys(object(value, field)).sort();
  const expected = [...fields].sort();
  if (actual.length !== expected.length || actual.some((name, index) => name !== expected[index])) fail(`${field} fields do not match the closed profile`);
  return value;
}
function parseJson(bytes, field) {
  let text;
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { fail(`${field} is not valid UTF-8`); }
  try { return JSON.parse(text); } catch { fail(`${field} is not valid JSON`); }
}
function compact(value, lf = true) { return Buffer.from(JSON.stringify(sortValue(value)) + (lf ? "\n" : ""), "utf8"); }
function sortValue(value) {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortValue(value[key])]));
  return value;
}
function requireCanonical(bytes, value, field, lf = true) {
  if (!bytes.equals(compact(value, lf))) fail(`${field} bytes are not canonical`);
}
function decodeBase64(value, field, expectedLength) {
  if (typeof value !== "string" || !BASE64.test(value)) fail(`${field} must be canonical standard base64`);
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) fail(`${field} must be canonical standard base64`);
  if (expectedLength !== undefined && decoded.length !== expectedLength) fail(`${field} must decode to exactly ${expectedLength} bytes`);
  return decoded;
}
function pae(payload) {
  const payloadType = Buffer.from(PAYLOAD_TYPE, "utf8");
  return Buffer.concat([Buffer.from(`DSSEv1 ${payloadType.length} `), payloadType, Buffer.from(` ${payload.length} `), payload]);
}
function safePath(value, field) {
  if (typeof value !== "string" || value.length === 0 || value.startsWith("/") || value.includes("\\") || /[\u0000-\u001f\u007f]/u.test(value)) fail(`${field} is unsafe`);
  const parts = value.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) fail(`${field} is unsafe`);
  return value;
}
function fileBinding(value, field, manifest = false) {
  closed(value, manifest ? ["path", "size_bytes", "sha256", "manifest_digest"] : ["path", "size_bytes", "sha256"], field);
  safePath(value.path, `${field}.path`);
  if (!Number.isSafeInteger(value.size_bytes) || value.size_bytes < 1) fail(`${field}.size_bytes is invalid`);
  if (!HEX_64.test(value.sha256) || (manifest && !HEX_64.test(value.manifest_digest))) fail(`${field} digest is invalid`);
}
async function stage(name) {
  const log = process.env.FKST_TESTING_PACKAGE_RELEASE_STAGE_LOG;
  if (log) await writeFile(log, `${name}\n`, { flag: "a" });
}
function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index], value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined || values.has(name)) fail("arguments must be unique --name value pairs");
    values.set(name, value);
  }
  const allowed = new Set(["--trusted-authorization-sha256", "--release", "--envelope", "--authorization", "--bundle", "--manifest", "--schema-catalog", "--schema-release"]);
  for (const name of values.keys()) if (!allowed.has(name)) fail(`unknown argument ${name}`);
  if (!values.has("--trusted-authorization-sha256")) fail("--trusted-authorization-sha256 is required exactly once");
  return values;
}
function verifyReleaseShape(release) {
  closed(release, ["schema", "canonicalization", "package", "bundle", "manifest", "schema_catalog", "schema_release", "source", "producer", "runtime", "executor", "reducer", "result_authority", "mappings", "creation_metadata"], "release");
  if (release.schema !== "testing-package-release.v1" || release.canonicalization !== "fkst-testing-package-release-canonical-json.v1") fail("release profile is unsupported");
  closed(release.package, ["package_id", "package_version", "package_content_sha256", "supported_profile", "capability"], "release.package");
  if (release.package.package_id !== "testing-runner" || release.package.package_version !== "1.0.0" || !HEX_64.test(release.package.package_content_sha256) || release.package.supported_profile !== "browser-deterministic.v1" || release.package.capability !== "browser.read-title.v1") fail("release package identity is unsupported");
  fileBinding(release.bundle, "release.bundle"); fileBinding(release.manifest, "release.manifest", true); fileBinding(release.schema_catalog, "release.schema_catalog"); fileBinding(release.schema_release, "release.schema_release");
  closed(release.source, ["repository_commit", "fkst_packages_commit", "fkst_substrate_commit"], "release.source");
  if (![release.source.repository_commit, release.source.fkst_packages_commit, release.source.fkst_substrate_commit].every((value) => HEX_40.test(value))) fail("release source identities must be exact commits");
  closed(release.producer, ["name", "version", "generator", "generator_version"], "release.producer");
  if (JSON.stringify(release.producer) !== JSON.stringify({ generator: "scripts/generate_testing_package_release.py", generator_version: "1.0.0", name: "fkst-packages-testing", version: "1.0.0" })) fail("release producer identity is unsupported");
  closed(release.runtime, ["lua", "platform"], "release.runtime");
  if (release.runtime.lua !== "5.4.0" || release.runtime.platform !== "linux-amd64") fail("release runtime identity is unsupported");
  closed(release.executor, ["module", "function", "executor_id"], "release.executor");
  if (release.executor.module !== "testing_package_executor.executor" || release.executor.function !== "execute" || release.executor.executor_id !== "testing-package-executor.browser-title.v1") fail("release executor identity is unsupported");
  closed(release.reducer, ["schema", "reducer_id", "reducer_version", "reducer_sha256", "policy_profile", "supported_result_contract_majors"], "release.reducer");
  const reducerWithoutDigest = { ...release.reducer }; delete reducerWithoutDigest.reducer_sha256;
  if (release.reducer.schema !== "testing-assertion-reducer-identity.v1" || release.reducer.reducer_id !== "testing.assertion-reducer.browser-title-equals" || release.reducer.reducer_version !== "1.0.0" || release.reducer.policy_profile !== "browser-title-equals.v1" || JSON.stringify(release.reducer.supported_result_contract_majors) !== '["testing-case-result-set.v2"]' || release.reducer.reducer_sha256 !== sha256(compact(reducerWithoutDigest, false))) fail("release reducer identity is unsupported");
  closed(release.result_authority, ["receipt_schema"], "release.result_authority");
  if (release.result_authority.receipt_schema !== "testing-result-authority-receipt.v1") fail("release result authority identity is unsupported");
  if (!Array.isArray(release.mappings) || release.mappings.length !== 1) fail("release must contain exactly one mapping");
  closed(release.mappings[0], ["entrypoint", "contract_major", "module", "function"], "release.mapping");
  if (JSON.stringify(release.mappings[0]) !== JSON.stringify({ contract_major: "testing-runner.v1", entrypoint: "testing-runner.run", function: "execute", module: "testing_package_executor.executor" })) fail("release mapping is unsupported");
  closed(release.creation_metadata, ["created_at", "build_id"], "release.creation_metadata");
  if (release.creation_metadata.created_at !== "2026-09-04T00:00:00Z" || release.creation_metadata.build_id !== "testing-package-release-walking-skeleton-v1") fail("release creation metadata is unsupported");
}
function verifyManifest(manifestBytes, manifest, release) {
  requireCanonical(manifestBytes, manifest, "manifest", false);
  const manifestWithoutDigest = { ...manifest }; delete manifestWithoutDigest.manifest_digest;
  if (manifest.manifest_digest !== sha256(compact(manifestWithoutDigest, false))) fail("manifest canonical digest mismatch");
  if (manifest.manifest_digest !== release.manifest.manifest_digest || sha256(manifestBytes) !== release.manifest.sha256 || manifestBytes.length !== release.manifest.size_bytes) fail("manifest persisted binding mismatch");
  closed(manifest, ["schema", "canonicalization", "package_id", "package_version", "source_commit", "package_content_sha256", "supported_contracts", "entrypoints", "semantic_capabilities", "runtime_requirements", "dependencies", "producer", "creation_metadata", "manifest_digest"], "manifest");
  if (manifest.schema !== "testing-package-manifest.v1" || manifest.canonicalization !== "fkst-testing-package-manifest-canonical-json.v1" || manifest.package_id !== "testing-runner" || manifest.package_version !== release.package.package_version || manifest.source_commit !== release.source.repository_commit || manifest.package_content_sha256 !== release.package.package_content_sha256) fail("manifest release identity mismatch");
  if (JSON.stringify(manifest.entrypoints) !== JSON.stringify([{ capabilities: ["browser.read-title.v1"], contract_major: "testing-runner.v1", name: "testing-runner.run" }])) fail("manifest must expose exactly testing-runner.run");
  if (manifest.dependencies.fkst_packages.commit !== release.source.fkst_packages_commit || manifest.dependencies.fkst_substrate.commit !== release.source.fkst_substrate_commit) fail("manifest dependency identity mismatch");
}
function verifyBundle(bundleBytes, bundle, release) {
  requireCanonical(bundleBytes, bundle, "bundle");
  closed(bundle, ["files", "schema"], "bundle");
  if (bundle.schema !== "testing-package-bundle.v1" || !Array.isArray(bundle.files) || bundle.files.length === 0) fail("bundle profile is unsupported");
  if (sha256(bundleBytes) !== release.bundle.sha256 || bundleBytes.length !== release.bundle.size_bytes) fail("bundle persisted binding mismatch");
  let previous = null;
  const decoded = [];
  const contentHash = createHash("sha256");
  for (const record of bundle.files) {
    closed(record, ["content_base64", "path", "sha256", "size_bytes"], "bundle file");
    safePath(record.path, "bundle file path");
    if (previous !== null && Buffer.compare(Buffer.from(previous), Buffer.from(record.path)) >= 0) fail("bundle paths must be unique and sorted by UTF-8 bytes");
    previous = record.path;
    if (!HEX_64.test(record.sha256) || !Number.isSafeInteger(record.size_bytes) || record.size_bytes < 0) fail("bundle file metadata is invalid");
    const bytes = decodeBase64(record.content_base64, "bundle file content_base64");
    if (bytes.length !== record.size_bytes || sha256(bytes) !== record.sha256) fail("bundle file content binding mismatch");
    contentHash.update(Buffer.from(record.path)); contentHash.update(Buffer.from([0, 0x66])); contentHash.update(bytes); contentHash.update(Buffer.from([0]));
    decoded.push({ path: record.path, bytes });
  }
  if (contentHash.digest("hex") !== release.package.package_content_sha256) fail("bundle package_content_sha256 mismatch");
  return decoded;
}
function executionTest(release) {
  return `local contract = require("contract.testing_package_executor")
local authority = require("contract.testing_result_authority")
local sha256 = require("contract.sha256").hex
local executor = require("testing_package_executor.executor")
local function ref(kind, name) return { kind=kind, ref="immutable://release/" .. name, sha256=sha256(name) } end
local approved = {
  package_release_ref=ref("testing-package-release", "release"), package_manifest_ref=ref("testing-package-manifest", "manifest"),
  source_ref=ref("testing-package-source", "source"), plan_ref=ref("testing-package-plan", "plan"),
  pql_input_ref=ref("testing-package-pql-input", "pql"), policy_ref=ref("testing-package-policy", "policy"),
  capability_set_ref=ref("testing-package-capability-set", "capabilities"),
}
local identity = { schema=contract.schemas.identity, package_id="testing-runner", package_version="1.0.0",
  package_content_sha256="${release.package.package_content_sha256}", manifest_digest="${release.manifest.manifest_digest}",
  entrypoint="testing-runner.run", contract_major="testing-runner.v1" }
local selected = { executor_id="testing-package-executor.browser-title.v1", name="testing-runner.run", contract_major="testing-runner.v1", capabilities={"browser.read-title.v1"} }
local admission = contract.compute_admission_digest(identity, "browser-deterministic.v1", approved, selected, "dedup-walking-skeleton", sha256)
local resolved = { schema=contract.schemas.resolved_invocation, executor=identity, execution_profile="browser-deterministic.v1",
  approved_input_refs=approved, source={schema=contract.schemas.source,source_id="fixture-home",target_url="http://127.0.0.1:4173/"},
  plan={schema=contract.schemas.plan,case_id="case-home-title",assertion={assertion_id="assert-home-title",expected="Fixture Home",required=true,type="title-equals"}},
  pql_input={schema=contract.schemas.pql_input,requirement_id="REQ-HOME-TITLE"}, selected_entrypoint=selected,
  admission_digest=admission, admission_receipt={schema=contract.schemas.admission_receipt,status="admitted",admission_key="dedup-walking-skeleton",admission_digest=admission},
  trace_id="trace-walking-skeleton", dedup_key="dedup-walking-skeleton" }
local browser_calls, intents, receipts = 0, 0, 0
local clock = {"2026-09-04T00:00:00Z", "2026-09-04T00:00:01Z"}; local clock_index = 0
local ports = {
  load_completed_execution=function() return nil end, load_result_authority_receipt=function() return nil end,
  load_canonical_artifact=function() return nil end, decode_json=function() error("unexpected decode") end,
  claim_execution=function(request) return {schema=contract.schemas.execution_claim_receipt,status="claimed",dedup_key=request.dedup_key,admission_digest=request.admission_digest,claim_id="claim-walking-skeleton"} end,
  load_effect_intent=function() return nil end, load_effect_receipt=function() return nil end,
  check_freshness=function() return true end,
  persist_effect_intent=function() intents=intents+1; return true end,
  browser_read_title=function() browser_calls=browser_calls+1; return {schema=contract.schemas.browser_read_title_receipt,effect_id=contract.effect_id,status="succeeded",observed_url=contract.target_url,observed_title="Fixture Home",evidence_refs={{kind="artifact",ref=".testing/runs/dedup-walking-skeleton/evidence/title.json",sha256=sha256("evidence")}},evidence_size_bytes=8} end,
  persist_effect_receipt=function() receipts=receipts+1; return true end,
  write_canonical=function(request) local names={ ["evidence-manifest"]="evidence-manifest.json",["case-result-set"]="case-result-set.json",["result-authority-receipt"]="result-authority-receipt.json" }; return {schema=contract.schemas.write_receipt,status="written",ref={kind="artifact",ref=".testing/runs/dedup-walking-skeleton/"..names[request.kind],sha256=request.canonical_sha256}} end,
  complete_execution=function(value) return value end,
  now=function() clock_index=clock_index+1; return clock[clock_index] end, sha256=sha256,
}
local receipt = executor.execute(resolved, ports)
authority.canonicalize(receipt, sha256)
assert(receipt.schema == "testing-result-authority-receipt.v1")
assert(receipt.classification == "passed")
assert(receipt.package_id == "testing-runner")
assert(receipt.executor_id == "testing-package-executor.browser-title.v1")
assert(browser_calls == 1 and intents == 1 and receipts == 1)
return { test_verified_release_execution = function() assert(true) end }
`;
}
async function executeVerified(decodedFiles, release) {
  const engine = process.env.FKST_TESTING_ENGINE_BIN || process.env.BIN;
  if (!engine) fail("FKST_TESTING_ENGINE_BIN or BIN is required for isolated executor invocation");
  const root = await mkdtemp(path.join(tmpdir(), "testing-package-release-"));
  const packageRoot = path.join(root, "packages/verified-testing-runner");
  try {
    for (const file of decodedFiles) {
      const target = path.join(packageRoot, file.path);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, file.bytes, { flag: "wx" });
    }
    await mkdir(path.join(packageRoot, "tests"), { recursive: true });
    await writeFile(path.join(root, "fkst.workspace.toml"), '[workspace]\nunits = ["packages/*"]\npackages = ["packages/*"]\nlibraries = []\n', { flag: "wx" });
    await writeFile(path.join(packageRoot, "fkst.toml"), 'kind = "package"\nname = "verified-testing-runner"\npersistence_class = "stateless_adapter"\n[code]\nroot = "libraries"\n', { flag: "wx" });
    await writeFile(path.join(packageRoot, "tests/release_execution_test.lua"), executionTest(release), { flag: "wx" });
    await stage("materialized");
    const result = spawnSync(engine, ["test", "--project-root", root, "--package-root", packageRoot], { encoding: "utf8", env: { ...process.env, LUA_PATH: "" } });
    if (result.status !== 0) fail(`isolated executor invocation failed: ${(result.stderr || result.stdout).trim()}`);
    await stage("executed");
  } finally { await rm(root, { recursive: true, force: true }); }
}

export async function verifyTestingPackageRelease(argv = process.argv.slice(2)) {
  const args = parseArguments(argv);
  const pin = args.get("--trusted-authorization-sha256");
  if (!HEX_64.test(pin)) fail("--trusted-authorization-sha256 must be exactly 64 lowercase hexadecimal characters");
  const authorizationPath = args.get("--authorization") ?? path.join(ROOT, "package-release/testing-package-release.v1.key.json");
  const authorizationBytes = await readFile(authorizationPath);
  if (sha256(authorizationBytes) !== pin) fail("authorization record SHA-256 does not match the independently provisioned trust pin");
  await stage("trust-pin-matched");

  const authorization = parseJson(authorizationBytes, "authorization record"); requireCanonical(authorizationBytes, authorization, "authorization record");
  closed(authorization, ["algorithm", "authorization", "keyid", "publicKey", "schema"], "authorization record");
  closed(authorization.authorization, ["payloadType", "predicateType", "subject"], "authorization scope");
  if (authorization.algorithm !== "ed25519" || authorization.schema !== "testing-package-release-key-authorization.v1" || authorization.keyid !== KEY_ID || authorization.authorization.payloadType !== PAYLOAD_TYPE || authorization.authorization.predicateType !== PREDICATE_TYPE || authorization.authorization.subject !== SUBJECT_NAME) fail("authorization record profile is unsupported");
  const publicKey = decodeBase64(authorization.publicKey, "authorization publicKey", 32);
  await stage("public-key-imported");

  const releasePath = args.get("--release") ?? path.join(ROOT, SUBJECT_NAME);
  const envelopePath = args.get("--envelope") ?? path.join(ROOT, "package-release/testing-package-release.v1.dsse.json");
  const bundlePath = args.get("--bundle") ?? path.join(ROOT, "package-release/testing-package-bundle.v1.json");
  const manifestPath = args.get("--manifest") ?? path.join(ROOT, "package-release/testing-package-manifest.v1.json");
  const catalogPath = args.get("--schema-catalog") ?? path.join(ROOT, "schema-release/testing-schema-catalog.v1.json");
  const schemaReleasePath = args.get("--schema-release") ?? path.join(ROOT, "schema-release/testing-package-schema-release.v1.json");
  const [releaseBytes, envelopeBytes, bundleBytes, manifestBytes, catalogBytes, schemaReleaseBytes] = await Promise.all([releasePath, envelopePath, bundlePath, manifestPath, catalogPath, schemaReleasePath].map((file) => readFile(file)));
  const envelope = parseJson(envelopeBytes, "DSSE envelope"); requireCanonical(envelopeBytes, envelope, "DSSE envelope");
  closed(envelope, ["payload", "payloadType", "signatures"], "DSSE envelope");
  if (envelope.payloadType !== PAYLOAD_TYPE || !Array.isArray(envelope.signatures) || envelope.signatures.length !== 1) fail("DSSE envelope profile is unsupported");
  closed(envelope.signatures[0], ["keyid", "sig"], "DSSE signature");
  if (envelope.signatures[0].keyid !== KEY_ID) fail("DSSE keyid is unsupported");
  const payload = decodeBase64(envelope.payload, "DSSE payload");
  const signature = decodeBase64(envelope.signatures[0].sig, "DSSE signature", 64);
  const key = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, publicKey]), format: "der", type: "spki" });
  if (!verifySignature(null, pae(payload), key, signature)) fail("Ed25519 DSSE verification failed");
  await stage("dsse-verified");
  const statement = parseJson(payload, "DSSE statement"); requireCanonical(payload, statement, "DSSE statement", false);
  closed(statement, ["_type", "predicate", "predicateType", "subject"], "DSSE statement"); closed(statement.predicate, [], "DSSE predicate");
  if (statement._type !== STATEMENT_TYPE || statement.predicateType !== PREDICATE_TYPE || !Array.isArray(statement.subject) || statement.subject.length !== 1) fail("DSSE statement profile is unsupported");
  closed(statement.subject[0], ["digest", "name"], "DSSE subject"); closed(statement.subject[0].digest, ["sha256"], "DSSE subject digest");
  if (statement.subject[0].name !== SUBJECT_NAME || statement.subject[0].digest.sha256 !== sha256(releaseBytes)) fail("DSSE release digest binding mismatch");
  const release = parseJson(releaseBytes, "release"); requireCanonical(releaseBytes, release, "release"); verifyReleaseShape(release);
  if (release.bundle.path !== path.relative(ROOT, bundlePath).split(path.sep).join("/") || release.manifest.path !== path.relative(ROOT, manifestPath).split(path.sep).join("/") || release.schema_catalog.path !== path.relative(ROOT, catalogPath).split(path.sep).join("/") || release.schema_release.path !== path.relative(ROOT, schemaReleasePath).split(path.sep).join("/")) fail("release bound paths do not match verifier inputs");
  if (sha256(catalogBytes) !== release.schema_catalog.sha256 || catalogBytes.length !== release.schema_catalog.size_bytes || sha256(schemaReleaseBytes) !== release.schema_release.sha256 || schemaReleaseBytes.length !== release.schema_release.size_bytes) fail("schema publication binding mismatch");
  await stage("release-verified");
  const manifest = parseJson(manifestBytes, "manifest"); verifyManifest(manifestBytes, manifest, release);
  await stage("manifest-verified");
  const bundle = parseJson(bundleBytes, "bundle"); const decodedFiles = verifyBundle(bundleBytes, bundle, release);
  await stage("bundle-verified");
  await executeVerified(decodedFiles, release);
  return { release, authorizationSha256: pin };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  verifyTestingPackageRelease().then(() => console.log("testing-package-release: VERIFIED AND EXECUTED")).catch((error) => { console.error(`error: ${error.message}`); process.exitCode = 1; });
}
