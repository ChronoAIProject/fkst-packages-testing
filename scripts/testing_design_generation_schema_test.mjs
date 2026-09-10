#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { registerSchema, validate } from "./node_schema/vendor/node_modules/@hyperjump/json-schema/draft-2020-12/index.js";
import { enforcePolicy, profileValid } from "./node_schema/validate.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaRoot = path.join(root, "schemas-next-release");
const fixtureRoot = path.join(root, "packages/testing-design/tests/fixtures/generation/v1");
const load = async (filename) => JSON.parse(await readFile(filename, "utf8"));
const policy = await load(path.join(root, "schema-release/testing-schema-policy.v1.json"));
const clone = (value) => structuredClone(value);

const applyCase = (document, testCase) => {
  let current = document;
  for (const segment of testCase.path.slice(0, -1)) current = current[segment];
  const leaf = testCase.path.at(-1);
  if (testCase.operation === "remove") delete current[leaf];
  else current[leaf] = clone(testCase.value);
  return document;
};

const atPath = (document, segments) => segments.reduce((current, segment) => current[segment], document);

const objectLocations = function* (schema, instance, segments = []) {
  if (schema.type === "object" && instance !== null && !Array.isArray(instance) && typeof instance === "object") {
    yield [segments, schema];
    for (const [key, childSchema] of Object.entries(schema.properties ?? {})) {
      if (Object.hasOwn(instance, key)) yield* objectLocations(childSchema, instance[key], [...segments, key]);
    }
  } else if (schema.type === "array" && Array.isArray(instance) && instance.length > 0) {
    yield* objectLocations(schema.items, instance[0], [...segments, 0]);
  }
};

const identities = [
  "testing-design.generate-request.v1",
  "testing-design.candidate-test-case-set.v1",
  "testing-design.generation-receipt.v1",
];
const schemas = new Map();
const resources = new Map();
const documents = new Map();
for (const identity of identities) {
  const schema = await load(path.join(schemaRoot, `${identity}.schema.json`));
  enforcePolicy(schema, policy, `schemas-next-release/${identity}.schema.json`);
  registerSchema(schema);
  schemas.set(identity, schema);
  resources.set(schema.$id, schema);
}

for (const [identity, fixture] of [
  [identities[0], "valid-request.json"],
  [identities[1], "valid-candidate-set.json"],
  [identities[2], "valid-receipt.json"],
]) {
  const document = await load(path.join(fixtureRoot, fixture));
  const result = await validate(schemas.get(identity).$id, document);
  assert.equal(result.valid && await profileValid(schemas.get(identity), document, resources, schemas.get(identity).$id), true, `${fixture} must validate`);
  documents.set(identity, document);
}

for (const [identity, base] of documents) {
  const document = seededDocument(base);
  const schema = schemas.get(identity);
  for (const [segments, objectSchema] of objectLocations(schema, document)) {
    const unknown = clone(document);
    atPath(unknown, segments).unknown = true;
    let result = await validate(schema.$id, unknown);
    assert.equal(result.valid, false, `unknown field at ${identity}${JSON.stringify(segments)} must be rejected`);
    for (const field of objectSchema.required ?? []) {
      const missing = clone(document);
      delete atPath(missing, segments)[field];
      result = await validate(schema.$id, missing);
      assert.equal(result.valid, false, `missing ${identity}${JSON.stringify(segments)}/${field} must be rejected`);
    }
  }
}

for (const fixture of ["valid-candidate-set-status-rejected.json", "valid-candidate-status-rejected.json"]) {
  const result = await validate(schemas.get(identities[1]).$id, await load(path.join(fixtureRoot, fixture)));
  assert.equal(result.valid, true, `${fixture} must validate`);
}
for (const fixture of ["invalid-candidate-script.json"]) {
  const result = await validate(schemas.get(identities[1]).$id, await load(path.join(fixtureRoot, fixture)));
  assert.equal(result.valid, false, `${fixture} must be rejected`);
}
for (const outcome of ["partial", "rejected", "budget-exhausted", "provider-error"]) {
  const fixture = `valid-receipt-outcome-${outcome}.json`;
  const result = await validate(schemas.get(identities[2]).$id, await load(path.join(fixtureRoot, fixture)));
  assert.equal(result.valid, true, `${fixture} must validate`);
}

const identityByDocument = new Map([
  ["request", identities[0]],
  ["candidate_set", identities[1]],
  ["receipt", identities[2]],
]);
function seededDocument(base) {
  const document = clone(base);
  if (document.schema === identities[1]) {
    const trace = document.candidates[0].traceability;
    for (const key of ["journey_refs", "risk_refs"]) trace[key] = clone(trace.requirement_refs);
    trace.existing_test_refs = [{ kind: "artifact", ref: ".testing/runs/design/existing-test-inventory.v1.json", sha256: "d".repeat(64) }];
  } else if (document.schema === identities[2]) {
    document.rejected_candidates = { total: 1, reasons: [{ code: "duplicate-candidate", count: 1 }] };
  }
  return document;
}

function* stringSamples(spec, controls) {
  const prefix = spec.prefix ?? "";
  yield [spec.minimum ?? `${prefix}x`, true];
  yield [prefix + "x".repeat(spec.max - prefix.length), true];
  yield ["", false];
  yield [prefix + "x".repeat(spec.max + 1 - prefix.length), false];
  yield [prefix + "界".repeat(Math.floor((spec.max - prefix.length) / 3) + 1), false];
  if (!spec.ascii_only) yield [prefix + "界".repeat(Math.floor((spec.max - prefix.length) / 3)) + "x".repeat((spec.max - prefix.length) % 3), true];
  for (const code of controls) {
    const control = String.fromCharCode(code);
    for (const value of [control + prefix + "x", prefix + "x" + control + "x", prefix + "x" + control]) yield [value, false];
  }
}

const matrix = await load(path.join(fixtureRoot, "boundary-matrix.json"));
let boundaryCount = 0;
const checkBoundary = async (identity, document, expected, label) => {
  const schema = schemas.get(identity);
  const result = await validate(schema.$id, document);
  assert.equal(result.valid && await profileValid(schema, document, resources, schema.$id), expected, label);
  boundaryCount += 1;
};
for (const spec of matrix.strings) {
  const identity = identityByDocument.get(spec.document);
  for (const sample of matrix.unicode_scalars) {
    const value = (spec.prefix ?? "") + String.fromCodePoint(...sample.codepoints);
    const document = applyCase(seededDocument(documents.get(identity)), { path: spec.path, operation: "set", value });
    await checkBoundary(identity, document, sample.valid && !spec.ascii_only, `scalar ${JSON.stringify(spec.path)} ${sample.codepoints}`);
  }
}
for (const spec of matrix.formats) {
  const identity = identityByDocument.get(spec.document);
  for (const sample of spec.values) {
    const document = applyCase(seededDocument(documents.get(identity)), { path: spec.path, operation: "set", value: sample.value });
    await checkBoundary(identity, document, sample.valid, `format ${JSON.stringify(spec.path)} ${JSON.stringify(sample.value)}`);
  }
}
for (const spec of matrix.fixed_strings) {
  const identity = identityByDocument.get(spec.document);
  const samples = [""];
  for (const code of matrix.controls) {
    const control = String.fromCharCode(code);
    samples.push(control + spec.value, spec.value.slice(0, 1) + control + spec.value.slice(1), spec.value + control);
  }
  if (spec.hex) samples.push("a".repeat(spec.hex - 1), "a".repeat(spec.hex + 1), "A".repeat(spec.hex), "g".repeat(spec.hex));
  for (const [index, value] of samples.entries()) {
    const document = applyCase(seededDocument(documents.get(identity)), { path: spec.path, operation: "set", value });
    await checkBoundary(identity, document, false, `fixed string ${JSON.stringify(spec.path)} sample ${index}`);
  }
}
for (const spec of matrix.strings) {
  const identity = identityByDocument.get(spec.document);
  let index = 0;
  for (const [value, expected] of stringSamples(spec, matrix.controls)) {
    const document = applyCase(seededDocument(documents.get(identity)), { path: spec.path, operation: "set", value });
    await checkBoundary(identity, document, expected, `string ${JSON.stringify(spec.path)} sample ${index++}`);
  }
}
for (const spec of matrix.integers) {
  const identity = identityByDocument.get(spec.document);
  for (const [value, expected] of [[spec.min, true], [spec.max, true], [spec.min - 1, false], [spec.max + 1, Boolean(spec.schema_unbounded)], [1.5, false], ["1", false], [true, false]]) {
    const document = applyCase(seededDocument(documents.get(identity)), { path: spec.path, operation: "set", value });
    await checkBoundary(identity, document, expected, `integer ${JSON.stringify(spec.path)} ${JSON.stringify(value)}`);
  }
}
for (const spec of matrix.unsafe) {
  const identity = identityByDocument.get(spec.document);
  for (const value of spec.values) {
    const document = applyCase(seededDocument(documents.get(identity)), { path: spec.path, operation: "set", value });
    await checkBoundary(identity, document, false, `unsafe ${JSON.stringify(spec.path)} ${JSON.stringify(value)}`);
  }
}
for (const spec of matrix.arrays) {
  for (const size of [0, 1, spec.maximum, spec.maximum + 1]) {
    const document = seededDocument(documents.get(identities[1]));
    const item = atPath(document, spec.path)[0];
    applyCase(document, { path: spec.path, operation: "set", value: Array.from({ length: size }, () => clone(item)) });
    await checkBoundary(identities[1], document, size >= 1 && size <= spec.maximum, `array ${JSON.stringify(spec.path)} size ${size}`);
  }
}
console.log(`generation boundary matrix: ${boundaryCount} shared cases passed`);
const corpus = await load(path.join(fixtureRoot, "rejection-cases.json"));
for (const testCase of corpus.cases) {
  const identity = identityByDocument.get(testCase.document);
  const schema = schemas.get(identity);
  const document = applyCase(clone(documents.get(identity)), testCase);
  const result = await validate(schema.$id, document);
  const actual = result.valid && await profileValid(schema, document, resources, schema.$id);
  assert.equal(actual, testCase.schema_valid, `shared case ${JSON.stringify(testCase.name)} validity`);
}
