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

const identities = [
  "testing-design.generate-request.v1",
  "testing-design.candidate-test-case-set.v1",
  "testing-design.generation-receipt.v1",
];
const schemas = new Map();
const resources = new Map();
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
  const result = await validate(schemas.get(identity).$id, await load(path.join(fixtureRoot, fixture)));
  assert.equal(result.valid && await profileValid(schemas.get(identity), await load(path.join(fixtureRoot, fixture)), resources, schemas.get(identity).$id), true, `${fixture} must validate`);
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
