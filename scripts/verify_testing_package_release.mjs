#!/usr/bin/env node
import { createHash, createPublicKey, timingSafeEqual, verify as verifySignature } from "node:crypto";
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
const AUTHORITY_ISSUER = "https://releases.chronoaiproject.org/fkst-packages-testing";
const SIGNATURE_PROFILE = "dsse-ed25519.v1";
const REVOCATION_AUTHORITY = "https://releases.chronoaiproject.org/fkst-packages-testing/revocations/v1";
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const HEX_64 = /^[0-9a-f]{64}$/;
const HEX_40 = /^[0-9a-f]{40}$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const UTC_TIMESTAMP = /^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\dZ$/;
const BUNDLE_PATHS = [
  "libraries/contract/canonical_json.lua",
  "libraries/contract/error_facts.lua",
  "libraries/contract/sha256.lua",
  "libraries/contract/strings.lua",
  "libraries/contract/testing_evidence_manifest.lua",
  "libraries/contract/testing_package_executor.lua",
  "libraries/contract/testing_result_authority.lua",
  "libraries/contract/testing_results.lua",
  "libraries/contract/time.lua",
  "libraries/testing_package_executor/executor.lua",
];
const RUNTIME_PATHS = [
  "libraries/contract/testing_package_executor.lua",
  "libraries/contract/testing_package_manifest.lua",
  "libraries/testing_runtime/json.lua",
  "libraries/testing_runtime/package_resolver.lua",
  "libraries/testing_runtime/testing_package_executor.lua",
];

function fail(message) { throw new Error(message); }
function sha256(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function digestMatches(actual, expected) {
  const actualBytes = Buffer.from(actual, "ascii");
  const expectedBytes = Buffer.from(expected, "ascii");
  return actualBytes.length === expectedBytes.length && timingSafeEqual(actualBytes, expectedBytes);
}
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
function timestamp(value, field) {
  if (typeof value !== "string" || !UTC_TIMESTAMP.test(value) || new Date(value).toISOString().replace(".000Z", "Z") !== value) fail(`${field} must be a canonical UTC timestamp`);
  return Date.parse(value);
}
function keyid(value, field) {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value, "utf8") > 128) fail(`${field} is invalid`);
  for (const character of value) {
    const codepoint = character.codePointAt(0);
    if (codepoint <= 0x1f || (codepoint >= 0x7f && codepoint <= 0x9f) || (codepoint >= 0xd800 && codepoint <= 0xdfff)) fail(`${field} is invalid`);
  }
  return value;
}
function metadataString(value, field) {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value, "utf8") > 180 || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) fail(`${field} is invalid`);
  return value;
}
async function stage(name) {
  const log = process.env.FKST_TESTING_PACKAGE_RELEASE_STAGE_LOG;
  if (log) await writeFile(log, `${name}\n`, { flag: "a" });
}
function parseArguments(argv) {
  const values = new Map();
  const revokedKeyids = new Set();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index], value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined || value.startsWith("--")) fail("arguments must be unique --name value pairs");
    if (name === "--revoked-keyid") {
      keyid(value, "--revoked-keyid");
      if (revokedKeyids.has(value)) fail("--revoked-keyid values must be unique");
      revokedKeyids.add(value);
      continue;
    }
    if (values.has(name)) fail("arguments must be unique --name value pairs");
    values.set(name, value);
  }
  const allowed = new Set(["--expected-release-sha256", "--trusted-authorization-sha256", "--verification-time", "--minimum-release-sequence", "--release", "--envelope", "--authorization", "--bundle", "--manifest", "--tool-catalog", "--schema-catalog", "--schema-release"]);
  for (const name of values.keys()) if (!allowed.has(name)) fail(`unknown argument ${name}`);
  if (!values.has("--expected-release-sha256")) fail("--expected-release-sha256 is required exactly once");
  if (!values.has("--trusted-authorization-sha256")) fail("--trusted-authorization-sha256 is required exactly once");
  if (!values.has("--verification-time")) fail("--verification-time is required exactly once");
  if (!values.has("--minimum-release-sequence")) fail("--minimum-release-sequence is required exactly once");
  timestamp(values.get("--verification-time"), "--verification-time");
  if (!/^[1-9][0-9]*$/.test(values.get("--minimum-release-sequence"))) fail("--minimum-release-sequence must be a positive safe decimal integer");
  const minimumReleaseSequence = Number(values.get("--minimum-release-sequence"));
  if (!Number.isSafeInteger(minimumReleaseSequence)) fail("--minimum-release-sequence must be a positive safe decimal integer");
  return { values, revokedKeyids, minimumReleaseSequence };
}
function verifyReleaseShape(release) {
  const successor = Object.hasOwn(release, "authority") || Object.hasOwn(release, "tool_catalog");
  closed(release, ["schema", "canonicalization", "package", "bundle", "manifest", "schema_catalog", "schema_release", "source", "producer", "runtime", "executor", "reducer", "result_authority", "mappings", "creation_metadata", ...(successor ? ["authority", "tool_catalog"] : [])], "release");
  if (release.schema !== "testing-package-release.v1" || release.canonicalization !== "fkst-testing-package-release-canonical-json.v1") fail("release profile is unsupported");
  closed(release.package, ["package_id", "package_version", "package_content_sha256", "supported_profile", "capability"], "release.package");
  if (release.package.package_id !== "testing-runner" || release.package.package_version !== "1.0.0" || !HEX_64.test(release.package.package_content_sha256) || release.package.supported_profile !== "browser-deterministic.v1" || release.package.capability !== "browser.read-title.v1") fail("release package identity is unsupported");
  fileBinding(release.bundle, "release.bundle"); fileBinding(release.manifest, "release.manifest", true); fileBinding(release.schema_catalog, "release.schema_catalog"); fileBinding(release.schema_release, "release.schema_release");
  if (successor) {
    fileBinding(release.tool_catalog, "release.tool_catalog");
    closed(release.authority, ["issuer", "keyid", "release_sequence", "revocation_authority", "signature_profile", "valid_from", "valid_until"], "release.authority");
    keyid(release.authority.keyid, "release.authority.keyid");
    if (release.authority.issuer !== AUTHORITY_ISSUER || release.authority.signature_profile !== SIGNATURE_PROFILE || release.authority.revocation_authority !== REVOCATION_AUTHORITY || !Number.isSafeInteger(release.authority.release_sequence) || release.authority.release_sequence < 1) fail("release authority profile is unsupported");
    timestamp(release.authority.valid_from, "release.authority.valid_from"); timestamp(release.authority.valid_until, "release.authority.valid_until");
    if (release.authority.valid_from >= release.authority.valid_until) fail("release authority validity interval is empty");
  }
  closed(release.source, ["repository_commit", "fkst_packages_commit", "fkst_substrate_commit"], "release.source");
  if (![release.source.repository_commit, release.source.fkst_packages_commit, release.source.fkst_substrate_commit].every((value) => HEX_40.test(value))) fail("release source identities must be exact commits");
  closed(release.producer, ["name", "version", "generator", "generator_version"], "release.producer");
  if (JSON.stringify(release.producer) !== JSON.stringify({ generator: "scripts/generate_testing_package_release.py", generator_version: "1.0.0", name: "fkst-packages-testing", version: "1.0.0" })) fail("release producer identity is unsupported");
  closed(release.runtime, ["lua", "platform"], "release.runtime");
  if (release.runtime.lua !== "5.4.0" || release.runtime.platform !== "linux-amd64") fail("release runtime identity is unsupported");
  closed(release.executor, ["module", "function", "executor_id"], "release.executor");
  metadataString(release.executor.module, "release.executor.module");
  metadataString(release.executor.function, "release.executor.function");
  metadataString(release.executor.executor_id, "release.executor.executor_id");
  closed(release.reducer, ["schema", "reducer_id", "reducer_version", "reducer_sha256", "policy_profile", "supported_result_contract_majors"], "release.reducer");
  const reducerWithoutDigest = { ...release.reducer }; delete reducerWithoutDigest.reducer_sha256;
  if (release.reducer.schema !== "testing-assertion-reducer-identity.v1" || release.reducer.reducer_id !== "testing.assertion-reducer.browser-title-equals" || release.reducer.reducer_version !== "1.0.0" || release.reducer.policy_profile !== "browser-title-equals.v1" || JSON.stringify(release.reducer.supported_result_contract_majors) !== '["testing-case-result-set.v2"]' || release.reducer.reducer_sha256 !== sha256(compact(reducerWithoutDigest, false))) fail("release reducer identity is unsupported");
  closed(release.result_authority, ["receipt_schema"], "release.result_authority");
  if (release.result_authority.receipt_schema !== "testing-result-authority-receipt.v1") fail("release result authority identity is unsupported");
  if (!Array.isArray(release.mappings) || release.mappings.length !== 1) fail("release must contain exactly one mapping");
  closed(release.mappings[0], ["entrypoint", "contract_major", "module", "function"], "release.mapping");
  if (release.mappings[0].entrypoint !== "testing-runner.run" || release.mappings[0].contract_major !== "testing-runner.v1") fail("release mapping is unsupported");
  metadataString(release.mappings[0].module, "release.mapping.module");
  metadataString(release.mappings[0].function, "release.mapping.function");
  closed(release.creation_metadata, ["created_at", "build_id"], "release.creation_metadata");
  timestamp(release.creation_metadata.created_at, "release.creation_metadata.created_at");
  if (release.creation_metadata.build_id !== "testing-package-release-walking-skeleton-v1") fail("release creation metadata is unsupported");
  return successor;
}
function verifyManifest(manifestBytes, manifest, release) {
  requireCanonical(manifestBytes, manifest, "manifest", false);
  closed(manifest, ["schema", "canonicalization", "package_id", "package_version", "source_commit", "package_content_sha256", "supported_contracts", "entrypoints", "semantic_capabilities", "runtime_requirements", "dependencies", "producer", "creation_metadata", "manifest_digest"], "manifest");
  const manifestWithoutDigest = { ...manifest }; delete manifestWithoutDigest.manifest_digest;
  if (!HEX_64.test(manifest.manifest_digest)) fail("manifest manifest_digest is invalid");
  if (manifest.manifest_digest !== sha256(compact(manifestWithoutDigest, false))) fail("manifest canonical digest mismatch");
  if (manifest.manifest_digest !== release.manifest.manifest_digest || sha256(manifestBytes) !== release.manifest.sha256 || manifestBytes.length !== release.manifest.size_bytes) fail("manifest persisted binding mismatch");
  if (manifest.schema !== "testing-package-manifest.v1" || manifest.canonicalization !== "fkst-testing-package-manifest-canonical-json.v1" || manifest.package_id !== "testing-runner" || manifest.package_version !== "1.0.0" || manifest.package_version !== release.package.package_version || manifest.source_commit !== release.source.repository_commit || manifest.package_content_sha256 !== release.package.package_content_sha256) fail("manifest release identity mismatch");
  closed(manifest.supported_contracts, ["majors", "canonicalization_profiles"], "manifest.supported_contracts");
  if (JSON.stringify(manifest.supported_contracts) !== JSON.stringify({ canonicalization_profiles: ["fkst-testing-package-manifest-canonical-json.v1"], majors: ["testing-runner.v1"] })) fail("manifest supported contracts are unsupported");
  if (!Array.isArray(manifest.entrypoints) || manifest.entrypoints.length !== 1) fail("manifest must expose exactly testing-runner.run");
  closed(manifest.entrypoints[0], ["capabilities", "contract_major", "name"], "manifest entrypoint");
  if (JSON.stringify(manifest.entrypoints) !== JSON.stringify([{ capabilities: ["browser.read-title.v1"], contract_major: "testing-runner.v1", name: "testing-runner.run" }])) fail("manifest must expose exactly testing-runner.run");
  if (JSON.stringify(manifest.semantic_capabilities) !== '["browser.read-title.v1"]') fail("manifest semantic capabilities are unsupported");
  closed(manifest.runtime_requirements, ["lua", "platforms"], "manifest.runtime_requirements");
  if (JSON.stringify(manifest.runtime_requirements) !== JSON.stringify({ lua: "5.4.0", platforms: ["linux-amd64"] })) fail("manifest runtime requirements are unsupported");
  closed(manifest.dependencies, ["fkst_packages", "fkst_substrate"], "manifest.dependencies");
  closed(manifest.dependencies.fkst_packages, ["id", "commit"], "manifest.dependencies.fkst_packages");
  closed(manifest.dependencies.fkst_substrate, ["id", "commit"], "manifest.dependencies.fkst_substrate");
  if (manifest.dependencies.fkst_packages.id !== "fkst-packages" || manifest.dependencies.fkst_substrate.id !== "fkst-substrate") fail("manifest dependency identity is unsupported");
  if (manifest.dependencies.fkst_packages.commit !== release.source.fkst_packages_commit || manifest.dependencies.fkst_substrate.commit !== release.source.fkst_substrate_commit) fail("manifest dependency identity mismatch");
  closed(manifest.producer, ["name", "version", "toolchain"], "manifest.producer");
  if (JSON.stringify(manifest.producer) !== JSON.stringify({ name: "fkst-packages-testing", toolchain: "testing-package-release-v1", version: "1.0.0" })) fail("manifest producer identity is unsupported");
  closed(manifest.creation_metadata, ["created_at", "build_id"], "manifest.creation_metadata");
  if (JSON.stringify(manifest.creation_metadata) !== JSON.stringify({ build_id: "testing-package-release-walking-skeleton-v1", created_at: "2026-09-04T00:00:00Z" })) fail("manifest creation metadata is unsupported");
}
function verifyToolCatalog(catalogBytes, catalog, release) {
  requireCanonical(catalogBytes, catalog, "tool catalog");
  closed(catalog, ["canonicalization", "execution_profile", "schema", "tools"], "tool catalog");
  if (catalog.schema !== "testing-package-tool-catalog.v1" || catalog.canonicalization !== "fkst-testing-package-tool-catalog-canonical-json.v1" || catalog.execution_profile !== release.package.supported_profile || !Array.isArray(catalog.tools) || catalog.tools.length !== 1) fail("tool catalog profile is unsupported");
  closed(catalog.tools[0], ["capability", "port"], "tool catalog entry");
  if (catalog.tools[0].capability !== release.package.capability) fail("tool catalog capability is unsupported");
  metadataString(catalog.tools[0].port, "tool catalog port");
  if (sha256(catalogBytes) !== release.tool_catalog.sha256 || catalogBytes.length !== release.tool_catalog.size_bytes) fail("tool catalog persisted binding mismatch");
}
function inputMatchesLogicalPath(inputPath, logicalPath) {
  return path.resolve(inputPath).split(path.sep).join("/").endsWith(`/${logicalPath}`);
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
  if (JSON.stringify(decoded.map((file) => file.path)) !== JSON.stringify(BUNDLE_PATHS)) fail("bundle files do not match the release allowlist");
  if (contentHash.digest("hex") !== release.package.package_content_sha256) fail("bundle package_content_sha256 mismatch");
  return decoded;
}
function packageContentBytes(decodedFiles) {
  const parts = [];
  for (const file of decodedFiles) parts.push(Buffer.from(file.path), Buffer.from([0, 0x66]), file.bytes, Buffer.from([0]));
  return Buffer.concat(parts);
}
function executionTest(semanticFacts, release, manifest, decodedFiles) {
  const documents = {
    package_release_ref: { schema: "testing-package-release.v1", release_id: `${semanticFacts.packageId}-${semanticFacts.packageVersion}` },
    package_manifest_ref: manifest,
    source_ref: { schema: "testing-package-source.v1", source_id: "fixture-home", target_url: "http://127.0.0.1:4173/" },
    plan_ref: { schema: "testing-package-plan.v1", case_id: "case-home-title", assertion: { assertion_id: "assert-home-title", expected: "Fixture Home", required: true, type: "title-equals" } },
    pql_input_ref: { schema: "testing-package-pql-input.v1", requirement_id: "REQ-HOME-TITLE" },
    policy_ref: { schema: "testing-package-policy.v1", execution_profile: semanticFacts.executionProfile, authorized_entrypoint: semanticFacts.entrypoint, allowed_capabilities: semanticFacts.capabilities },
    capability_set_ref: { schema: "testing-package-capability-set.v1", capabilities: semanticFacts.capabilities },
  };
  const packageContentHex = packageContentBytes(decodedFiles).toString("hex");
  return `local contract = require("contract.testing_package_executor")
local error_facts = require("contract.error_facts")
local authority = require("contract.testing_result_authority")
local sha256 = require("contract.sha256").hex
local runtime_json = require("testing_runtime.json")
local runtime_executor = require("testing_runtime.testing_package_executor")
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end
local documents = copy(json.decode(${JSON.stringify(JSON.stringify(documents))}))
local storage, approved = {}, {}
local refs = {
  package_release_ref={kind="testing-package-release",ref="immutable://release/package-release.json"},
  package_manifest_ref={kind="testing-package-manifest",ref="immutable://release/package-manifest.json"},
  source_ref={kind="testing-package-source",ref="immutable://release/source.json"},
  plan_ref={kind="testing-package-plan",ref="immutable://release/plan.json"},
  pql_input_ref={kind="testing-package-pql-input",ref="immutable://release/pql.json"},
  policy_ref={kind="testing-package-policy",ref="immutable://release/policy.json"},
  capability_set_ref={kind="testing-package-capability-set",ref="immutable://release/capabilities.json"},
}
for _, field in ipairs(contract.reference_order) do
  local bytes = runtime_json.encode(documents[field])
  storage[refs[field].ref] = bytes
  approved[field] = {kind=refs[field].kind,ref=refs[field].ref,sha256=sha256(bytes)}
end
local function request(profile)
  return {schema=contract.schemas.request,executor={schema=contract.schemas.identity,
    package_id=${JSON.stringify(semanticFacts.packageId)},package_version=${JSON.stringify(semanticFacts.packageVersion)},
    package_content_sha256=${JSON.stringify(release.package.package_content_sha256)},manifest_digest=${JSON.stringify(release.manifest.manifest_digest)},
    entrypoint=${JSON.stringify(semanticFacts.entrypoint)},contract_major=${JSON.stringify(semanticFacts.contractMajor)}},
    execution_profile=profile or ${JSON.stringify(semanticFacts.executionProfile)},approved_input_refs=approved,
    trace_id="trace-walking-skeleton",dedup_key="dedup-walking-skeleton"}
end
local package_content = (${JSON.stringify(packageContentHex)}):gsub("..", function(byte) return string.char(tonumber(byte, 16)) end)
local browser_calls, intents, receipts = 0, 0, 0
local clock = {"2026-09-04T00:00:00Z", "2026-09-04T00:00:01Z"}; local clock_index = 0
local ports = {
  load_immutable=function(ref) return assert(storage[ref.ref], "unexpected immutable reference") end,
  load_package_content=function() return package_content end,
  check_runtime_compatibility=function(value) return value.runtime_requirements.lua == "5.4.0"
    and value.runtime_requirements.platforms[1] == "linux-amd64"
    and value.dependencies.fkst_packages.commit == ${JSON.stringify(release.source.fkst_packages_commit)}
    and value.dependencies.fkst_substrate.commit == ${JSON.stringify(release.source.fkst_substrate_commit)} end,
  admit_resolution=function(value) return {schema=contract.schemas.admission_receipt,status="admitted",admission_key=value.admission_key,admission_digest=value.admission_digest} end,
  load_completed_execution=function() return nil end, load_result_authority_receipt=function() return nil end,
  load_canonical_artifact=function() return nil end, decode_json=function(bytes) return copy(json.decode(bytes)) end,
  claim_execution=function(value) return {schema=contract.schemas.execution_claim_receipt,status="claimed",dedup_key=value.dedup_key,admission_digest=value.admission_digest,claim_id="claim-walking-skeleton"} end,
  load_effect_intent=function() return nil end, load_effect_receipt=function() return nil end,
  check_freshness=function() return true end,
  persist_effect_intent=function() intents=intents+1; return true end,
  browser_read_title=function() browser_calls=browser_calls+1; return {schema=contract.schemas.browser_read_title_receipt,effect_id=contract.effect_id,status="succeeded",observed_url=contract.target_url,observed_title="Fixture Home",evidence_refs={{kind="artifact",ref=".testing/runs/dedup-walking-skeleton/evidence/title.json",sha256=sha256("evidence")}},evidence_size_bytes=8} end,
  persist_effect_receipt=function() receipts=receipts+1; return true end,
  write_canonical=function(value) local names={ ["evidence-manifest"]="evidence-manifest.json",["case-result-set"]="case-result-set.json",["result-authority-receipt"]="result-authority-receipt.json" }; return {schema=contract.schemas.write_receipt,status="written",ref={kind="artifact",ref=".testing/runs/dedup-walking-skeleton/"..names[value.kind],sha256=value.canonical_sha256}} end,
  complete_execution=function(value) return value end,
  now=function() clock_index=clock_index+1; return clock[clock_index] end, sha256=sha256,
}
local original_mappings = contract.semantic_mappings
contract.semantic_mappings = {}
local ok, err = pcall(runtime_executor.execute, request(), ports)
assert(not ok and error_facts.error_class_from_message(err) == "unsupported-mapping", tostring(err))
contract.semantic_mappings = {original_mappings[1], original_mappings[1]}
ok, err = pcall(runtime_executor.execute, request(), ports)
assert(not ok and error_facts.error_class_from_message(err) == "mapping-ambiguous", tostring(err))
contract.semantic_mappings = original_mappings
ok, err = pcall(runtime_executor.execute, request("unsupported-profile.v1"), ports)
assert(not ok and error_facts.error_class_from_message(err) == "unsupported-mapping", tostring(err))
assert(browser_calls == 0 and intents == 0 and receipts == 0)
local captured_bindings
local create_receipt = authority.create_receipt
authority.create_receipt = function(bindings, sha256_fn) captured_bindings = bindings; return create_receipt(bindings, sha256_fn) end
local receipt = runtime_executor.execute(request(), ports)
authority.create_receipt = create_receipt
authority.validate_receipt(receipt, captured_bindings, sha256)
authority.canonicalize(receipt, sha256)
assert(receipt.schema == "testing-result-authority-receipt.v1")
assert(receipt.classification == "passed")
assert(receipt.package_id == ${JSON.stringify(semanticFacts.packageId)})
assert(receipt.executor_id == contract.executor_id)
assert(browser_calls == 1 and intents == 1 and receipts == 1)
return { test_verified_release_execution = function() assert(true) end }
`;
}

async function executeVerified(decodedFiles, verified) {
  const engine = process.env.FKST_TESTING_ENGINE_BIN || process.env.BIN;
  if (!engine) fail("FKST_TESTING_ENGINE_BIN or BIN is required for isolated executor invocation");
  const root = await mkdtemp(path.join(tmpdir(), "testing-package-release-"));
  const packageRoot = path.join(root, "packages/verified-testing-runner");
  try {
    for (const file of decodedFiles) {
      if (RUNTIME_PATHS.includes(file.path)) continue;
      const target = path.join(packageRoot, file.path);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, file.bytes, { flag: "wx" });
    }
    for (const relative of RUNTIME_PATHS) {
      const target = path.join(packageRoot, relative);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, await readFile(path.join(ROOT, relative)), { flag: "wx" });
    }
    await mkdir(path.join(packageRoot, "tests"), { recursive: true });
    await writeFile(path.join(root, "fkst.workspace.toml"), '[workspace]\nunits = ["packages/*"]\npackages = ["packages/*"]\nlibraries = []\n', { flag: "wx" });
    await writeFile(path.join(packageRoot, "fkst.toml"), 'kind = "package"\nname = "verified-testing-runner"\npersistence_class = "stateless_adapter"\n[code]\nroot = "libraries"\n', { flag: "wx" });
    await writeFile(path.join(packageRoot, "tests/release_execution_test.lua"), executionTest(verified.semanticFacts, verified.release, verified.manifest, decodedFiles), { flag: "wx" });
    await stage("materialized");
    const result = spawnSync(engine, ["test", "--project-root", root, "--package-root", packageRoot], { encoding: "utf8", env: { ...process.env, LUA_PATH: "" } });
    if (result.status !== 0) fail(`isolated executor invocation failed: ${(result.stderr || result.stdout).trim()}`);
    await stage("executed");
  } finally { await rm(root, { recursive: true, force: true }); }
}

export async function verifyTestingPackageRelease(argv = process.argv.slice(2)) {
  const parsedArguments = parseArguments(argv);
  const args = parsedArguments.values;
  const expectedReleaseSha256 = args.get("--expected-release-sha256");
  const pin = args.get("--trusted-authorization-sha256");
  if (!HEX_64.test(expectedReleaseSha256)) fail("--expected-release-sha256 must be exactly 64 lowercase hexadecimal characters");
  if (!HEX_64.test(pin)) fail("--trusted-authorization-sha256 must be exactly 64 lowercase hexadecimal characters");

  const releasePath = args.get("--release") ?? path.join(ROOT, SUBJECT_NAME);
  const releaseBytes = await readFile(releasePath);
  const releaseSha256 = sha256(releaseBytes);
  if (!digestMatches(releaseSha256, expectedReleaseSha256)) fail("release descriptor SHA-256 does not match the independently provisioned expected digest");
  await stage("release-digest-matched");

  const release = parseJson(releaseBytes, "release"); requireCanonical(releaseBytes, release, "release");
  const successor = verifyReleaseShape(release);
  const verificationTime = timestamp(args.get("--verification-time"), "--verification-time");
  if (successor) {
    if (release.authority.release_sequence < parsedArguments.minimumReleaseSequence) fail("release sequence is below the consumer minimum");
    if (verificationTime < timestamp(release.authority.valid_from, "release.authority.valid_from") || verificationTime >= timestamp(release.authority.valid_until, "release.authority.valid_until")) fail("release is outside its authorized validity interval");
    if (parsedArguments.revokedKeyids.has(release.authority.keyid)) fail("release signing key is revoked");
  }
  const expectedKeyid = successor ? release.authority.keyid : KEY_ID;

  const authorizationPath = args.get("--authorization") ?? path.join(ROOT, "package-release/testing-package-release.v1.key.json");
  const authorizationBytes = await readFile(authorizationPath);
  if (!digestMatches(sha256(authorizationBytes), pin)) fail("authorization record SHA-256 does not match the independently provisioned trust pin");
  await stage("trust-pin-matched");

  const authorization = parseJson(authorizationBytes, "authorization record"); requireCanonical(authorizationBytes, authorization, "authorization record");
  closed(authorization, ["algorithm", "authorization", "keyid", "publicKey", "schema"], "authorization record");
  closed(authorization.authorization, ["payloadType", "predicateType", "subject"], "authorization scope");
  if (authorization.algorithm !== "ed25519" || authorization.schema !== "testing-package-release-key-authorization.v1" || authorization.keyid !== expectedKeyid || authorization.authorization.payloadType !== PAYLOAD_TYPE || authorization.authorization.predicateType !== PREDICATE_TYPE || authorization.authorization.subject !== SUBJECT_NAME) fail("authorization record profile is unsupported");
  const publicKey = decodeBase64(authorization.publicKey, "authorization publicKey", 32);
  await stage("public-key-imported");

  const envelopePath = args.get("--envelope") ?? path.join(ROOT, "package-release/testing-package-release.v1.dsse.json");
  const bundlePath = args.get("--bundle") ?? path.join(ROOT, "package-release/testing-package-bundle.v1.json");
  const manifestPath = args.get("--manifest") ?? path.join(ROOT, "package-release/testing-package-manifest.v1.json");
  const toolCatalogPath = args.get("--tool-catalog");
  const catalogPath = args.get("--schema-catalog") ?? path.join(ROOT, "schema-release/testing-schema-catalog.v1.json");
  const schemaReleasePath = args.get("--schema-release") ?? path.join(ROOT, "schema-release/testing-package-schema-release.v1.json");
  if (successor && !toolCatalogPath) fail("--tool-catalog is required for successor releases");
  const envelopeBytes = await readFile(envelopePath);
  const envelope = parseJson(envelopeBytes, "DSSE envelope"); requireCanonical(envelopeBytes, envelope, "DSSE envelope");
  closed(envelope, ["payload", "payloadType", "signatures"], "DSSE envelope");
  if (envelope.payloadType !== PAYLOAD_TYPE || !Array.isArray(envelope.signatures) || envelope.signatures.length !== 1) fail("DSSE envelope profile is unsupported");
  closed(envelope.signatures[0], ["keyid", "sig"], "DSSE signature");
  if (envelope.signatures[0].keyid !== expectedKeyid) fail("DSSE keyid is unsupported");
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
  const sourceCommit = (await readFile(path.join(ROOT, "package-release/testing-package-release.v1.source-commit"), "ascii")).trim();
  const packagesPin = (await readFile(path.join(ROOT, ".fkst/conformance/fkst-packages.pin"), "ascii")).split(/\r?\n/u).map((line) => line.trim()).filter((line) => line && !line.startsWith("#")).at(-1);
  const substratePin = (await readFile(path.join(ROOT, ".fkst/substrate-ref"), "ascii")).trim();
  if (release.source.repository_commit !== sourceCommit || release.source.fkst_packages_commit !== packagesPin || release.source.fkst_substrate_commit !== substratePin) fail("release source identities do not match committed provenance pins");
  const gitObject = spawnSync("git", ["cat-file", "-e", `${sourceCommit}^{commit}`], { cwd: ROOT, encoding: "utf8" });
  if (gitObject.status !== 0) fail("release repository source commit is unavailable");
  if (!inputMatchesLogicalPath(bundlePath, release.bundle.path) || !inputMatchesLogicalPath(manifestPath, release.manifest.path) || !inputMatchesLogicalPath(catalogPath, release.schema_catalog.path) || !inputMatchesLogicalPath(schemaReleasePath, release.schema_release.path) || (successor && !inputMatchesLogicalPath(toolCatalogPath, release.tool_catalog.path))) fail("release bound paths do not match verifier inputs");
  const [bundleBytes, manifestBytes, toolCatalogBytes, catalogBytes, schemaReleaseBytes] = await Promise.all([bundlePath, manifestPath, toolCatalogPath, catalogPath, schemaReleasePath].map((file) => file ? readFile(file) : null));
  if (sha256(catalogBytes) !== release.schema_catalog.sha256 || catalogBytes.length !== release.schema_catalog.size_bytes || sha256(schemaReleaseBytes) !== release.schema_release.sha256 || schemaReleaseBytes.length !== release.schema_release.size_bytes) fail("schema publication binding mismatch");
  if (successor) verifyToolCatalog(toolCatalogBytes, parseJson(toolCatalogBytes, "tool catalog"), release);
  await stage("release-verified");
  const manifest = parseJson(manifestBytes, "manifest"); verifyManifest(manifestBytes, manifest, release);
  await stage("manifest-verified");
  const bundle = parseJson(bundleBytes, "bundle"); const decodedFiles = verifyBundle(bundleBytes, bundle, release);
  await stage("bundle-verified");
  const semanticFacts = {
    executionProfile: release.package.supported_profile,
    packageId: release.package.package_id,
    packageVersion: release.package.package_version,
    entrypoint: release.mappings[0].entrypoint,
    contractMajor: release.mappings[0].contract_major,
    capabilities: [...manifest.entrypoints[0].capabilities],
  };
  await executeVerified(decodedFiles, { semanticFacts, release, manifest });
  return semanticFacts;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  verifyTestingPackageRelease().then(() => console.log("testing-package-release: VERIFIED AND EXECUTED")).catch((error) => { console.error(`error: ${error.message}`); process.exitCode = 1; });
}
