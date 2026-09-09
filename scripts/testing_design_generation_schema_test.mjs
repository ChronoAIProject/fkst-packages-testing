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

for (const [identity, document] of documents) {
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

for (const fixture of ["invalid-candidate-script.json", "invalid-candidate-set-status.json", "invalid-candidate-status.json"]) {
  const result = await validate(schemas.get(identities[1]).$id, await load(path.join(fixtureRoot, fixture)));
  assert.equal(result.valid, false, `${fixture} must be rejected`);
}
for (const outcome of ["partial", "rejected", "budget-exhausted", "provider-error"]) {
  const fixture = `invalid-receipt-outcome-${outcome}.json`;
  const result = await validate(schemas.get(identities[2]).$id, await load(path.join(fixtureRoot, fixture)));
  assert.equal(result.valid, false, `${fixture} must be rejected`);
}

const identityByDocument = new Map([
  ["request", identities[0]],
  ["candidate_set", identities[1]],
  ["receipt", identities[2]],
]);
const corpus = await load(path.join(fixtureRoot, "rejection-cases.json"));
for (const testCase of corpus.cases) {
  const identity = identityByDocument.get(testCase.document);
  const schema = schemas.get(identity);
  const document = applyCase(clone(documents.get(identity)), testCase);
  const result = await validate(schema.$id, document);
  const actual = result.valid && await profileValid(schema, document, resources, schema.$id);
  assert.equal(actual, testCase.schema_valid, `shared case ${JSON.stringify(testCase.name)} validity`);
}
