#!/usr/bin/env node
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PAYLOAD_TYPE = "application/vnd.in-toto+json";
const STATEMENT_TYPE = "https://in-toto.io/Statement/v1";
const PREDICATE_TYPE = "https://chronoaiproject.github.io/fkst-packages-testing/attestations/testing-package-schema-release/v1";
const SUBJECT_NAME = "schema-release/testing-package-schema-release.v1.json";
const KEY_ID = "fkst-packages-testing-schema-release-v1-2026-09-02";
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function fail(message) {
  throw new Error(message);
}

function object(value, field) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) fail(`${field} must be an object`);
  return value;
}

function required(value, fields, field) {
  for (const name of fields) if (!Object.hasOwn(value, name)) fail(`${field} is missing ${name}`);
}

function decodeBase64(value, field, expectedLength) {
  if (typeof value !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) fail(`${field} must be standard base64`);
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) fail(`${field} must use canonical standard base64`);
  if (expectedLength !== undefined && decoded.length !== expectedLength) fail(`${field} must decode to exactly ${expectedLength} bytes`);
  return decoded;
}

function parseJson(bytes, field) {
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch {
    fail(`${field} is not valid JSON`);
  }
}

function pae(payload) {
  const payloadType = Buffer.from(PAYLOAD_TYPE, "utf8");
  return Buffer.concat([
    Buffer.from(`DSSEv1 ${payloadType.length} `, "ascii"), payloadType,
    Buffer.from(` ${payload.length} `, "ascii"), payload,
  ]);
}

function expectedStatement(releaseBytes) {
  const digest = createHash("sha256").update(releaseBytes).digest("hex");
  return Buffer.from(JSON.stringify({
    _type: STATEMENT_TYPE,
    predicate: {},
    predicateType: PREDICATE_TYPE,
    subject: [{ digest: { sha256: digest }, name: SUBJECT_NAME }],
  }), "utf8");
}

async function main() {
  const argumentsByName = new Map();
  for (let index = 2; index < process.argv.length; index += 2) {
    const name = process.argv[index];
    const value = process.argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) fail("arguments must be --name value pairs");
    argumentsByName.set(name, value);
  }
  const releasePath = argumentsByName.get("--release") ?? path.join(ROOT, SUBJECT_NAME);
  const envelopePath = argumentsByName.get("--envelope") ?? path.join(ROOT, "schema-release/testing-package-schema-release.v1.dsse.json");
  const authorizationPath = argumentsByName.get("--authorization") ?? path.join(ROOT, "schema-release/testing-package-schema-release.v1.key.json");
  const [releaseBytes, envelopeBytes, authorizationBytes] = await Promise.all([
    readFile(releasePath), readFile(envelopePath), readFile(authorizationPath),
  ]);

  const envelope = object(parseJson(envelopeBytes, "envelope"), "envelope");
  required(envelope, ["payloadType", "payload", "signatures"], "envelope");
  if (envelope.payloadType !== PAYLOAD_TYPE) fail("payloadType does not match the authorized profile");
  if (!Array.isArray(envelope.signatures) || envelope.signatures.length !== 1) fail("signatures must contain exactly one signature");
  const signatureEntry = object(envelope.signatures[0], "signature");
  required(signatureEntry, ["keyid", "sig"], "signature");
  if (typeof signatureEntry.keyid !== "string" || signatureEntry.keyid.length === 0) fail("keyid must be non-empty");
  const payload = decodeBase64(envelope.payload, "payload");
  const signature = decodeBase64(signatureEntry.sig, "sig", 64);

  const authorization = object(parseJson(authorizationBytes, "authorization"), "authorization");
  const authorizationFields = ["algorithm", "authorization", "keyid", "publicKey", "schema"];
  if (Object.keys(authorization).sort().join("\0") !== authorizationFields.sort().join("\0")) fail("authorization fields do not match the closed profile");
  if (authorization.schema !== "testing-package-schema-release-key-authorization.v1" || authorization.algorithm !== "ed25519") fail("authorization profile is unsupported");
  if (authorization.keyid !== KEY_ID || signatureEntry.keyid !== authorization.keyid) fail("keyid does not match the committed authorization");
  const scope = object(authorization.authorization, "authorization.authorization");
  if (Object.keys(scope).sort().join("\0") !== ["payloadType", "predicateType", "subject"].join("\0") ||
      scope.payloadType !== PAYLOAD_TYPE || scope.predicateType !== PREDICATE_TYPE || scope.subject !== SUBJECT_NAME) {
    fail("authorization scope does not match the release profile");
  }
  const publicKey = decodeBase64(authorization.publicKey, "publicKey", 32);
  const key = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, publicKey]), format: "der", type: "spki" });
  if (!verify(null, pae(payload), key, signature)) fail("Ed25519 signature verification failed");

  parseJson(payload, "statement payload");
  if (!payload.equals(expectedStatement(releaseBytes))) fail("statement payload does not match the release digest profile");
  console.log("testing-schema-release-attestation: VERIFIED");
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
});
