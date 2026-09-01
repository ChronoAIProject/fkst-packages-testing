#!/usr/bin/env node
import { readFile, readdir } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
import process from "node:process";
import { removeUriSchemePlugin } from "./vendor/node_modules/@hyperjump/browser/lib/index.js";
import { registerSchema, validate } from "./vendor/node_modules/@hyperjump/json-schema/draft-2020-12/index.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const POLICY_PATH = path.join(ROOT, "schema-release/testing-schema-policy.v1.json");
const FIXTURE_INDEX = path.join(ROOT, "schema-fixtures/testing-schema-fixtures.v1.json");
const STANDARDS_INDEX = path.join(ROOT, "scripts/node_schema/standards-corpus.json");
const STANDARDS_ROOT = path.join(ROOT, "scripts/node_schema/vendor");

const loadJson = async (filename) => JSON.parse(await readFile(filename, "utf8"));
const pointer = (document, fragment) => {
  if (fragment === "" || fragment === "#") return document;
  if (!fragment.startsWith("#/")) throw new Error(`unsupported JSON Pointer fragment: ${fragment}`);
  return fragment.slice(2).split("/").reduce((value, token) => value[token.replaceAll("~1", "/").replaceAll("~0", "~")], document);
};
const splitRef = (reference, baseUri) => {
  const resolved = new URL(reference, baseUri).href;
  const index = resolved.indexOf("#");
  return [index === -1 ? resolved : resolved.slice(0, index), index === -1 ? "" : resolved.slice(index)];
};
const utf8Length = (value) => Buffer.byteLength(value, "utf8");
const validDateTime = (value) => {
  if (typeof value !== "string") return true;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return false;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, , zone] = match;
  const year = Number(yearText), month = Number(monthText), day = Number(dayText);
  const hour = Number(hourText), minute = Number(minuteText), second = Number(secondText);
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) return false;
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (day < 1 || day > days[month - 1]) return false;
  if (zone !== "Z") {
    const zoneHour = Number(zone.slice(1, 3)), zoneMinute = Number(zone.slice(4, 6));
    if (zoneHour > 23 || zoneMinute > 59) return false;
  }
  return true;
};

const enforcePolicy = (schema, policy, source, location = "#") => {
  if (typeof schema === "boolean") return;
  if (schema === null || typeof schema !== "object" || Array.isArray(schema)) throw new Error(`${source}:${location}: schema location must be an object or Boolean`);
  for (const [keyword, value] of Object.entries(schema)) {
    if (!policy.allowed_keywords.includes(keyword)) throw new Error(`${source}:${location}: unsupported keyword ${keyword}`);
    if (keyword === "$schema" && value !== policy.draft) throw new Error(`${source}:${location}: unsupported draft ${value}`);
    if (keyword === "format" && !policy.allowed_formats.includes(value)) throw new Error(`${source}:${location}: unsupported format ${value}`);
    if ((keyword === "properties" || keyword === "$defs") && value && typeof value === "object") {
      for (const [name, child] of Object.entries(value)) enforcePolicy(child, policy, source, `${location}/${keyword}/${name}`);
    } else if (["allOf", "anyOf", "oneOf"].includes(keyword) && Array.isArray(value)) {
      value.forEach((child, index) => enforcePolicy(child, policy, source, `${location}/${keyword}/${index}`));
    } else if (["additionalProperties", "items", "contains", "not", "if", "then", "else"].includes(keyword) && (typeof value === "boolean" || (value && typeof value === "object"))) {
      enforcePolicy(value, policy, source, `${location}/${keyword}`);
    }
  }
};

const profileValid = async (schema, instance, resources, baseUri) => {
  if (typeof schema === "boolean") return true;
  const nestedId = typeof schema.$id === "string" ? new URL(schema.$id, baseUri).href : baseUri;
  if (typeof schema["x-fkst-maxUtf8Bytes"] === "number" && typeof instance === "string" && utf8Length(instance) > schema["x-fkst-maxUtf8Bytes"]) return false;
  if (typeof schema.format === "string" && typeof instance === "string") {
    if (schema.format === "date-time" && !validDateTime(instance)) return false;
    const bound = /^fkst-utf8-max-(\d+)$/.exec(schema.format);
    if (bound && utf8Length(instance) > Number(bound[1])) return false;
  }
  if (typeof schema.$ref === "string") {
    const [resourceUri, fragment] = splitRef(schema.$ref, nestedId);
    const target = resources.get(resourceUri);
    if (!target || !(await profileValid(pointer(target, fragment), instance, resources, resourceUri))) return false;
  }
  if (schema.properties && instance && typeof instance === "object" && !Array.isArray(instance)) {
    for (const [name, child] of Object.entries(schema.properties)) if (Object.hasOwn(instance, name) && !(await profileValid(child, instance[name], resources, nestedId))) return false;
  }
  if (schema.items && Array.isArray(instance)) for (const item of instance) if (!(await profileValid(schema.items, item, resources, nestedId))) return false;
  for (const child of schema.allOf || []) if (!(await profileValid(child, instance, resources, nestedId))) return false;
  return true;
};

export async function runConformance() {
  const policy = await loadJson(POLICY_PATH);
  const schemaFiles = (await readdir(path.join(ROOT, "schemas"))).filter((name) => name.endsWith(".schema.json")).sort();
  const resources = new Map();
  for (const filename of schemaFiles) {
    const source = `schemas/${filename}`;
    const schema = await loadJson(path.join(ROOT, source));
    enforcePolicy(schema, policy, source);
    if (typeof schema.$id !== "string" || resources.has(schema.$id)) throw new Error(`missing or duplicate schema resource ID: ${source}`);
    resources.set(schema.$id, schema);
    registerSchema(schema);
  }
  const remotesRoot = path.join(STANDARDS_ROOT, "json-schema-test-suite/remotes");
  for (const relative of (await readdir(remotesRoot, { recursive: true })).filter((name) => name.endsWith(".json")).sort()) {
    const remote = await loadJson(path.join(remotesRoot, relative));
    if (remote.$schema === undefined || remote.$schema === policy.draft) registerSchema(remote, `http://localhost:1234/${relative.replaceAll(path.sep, "/")}`, policy.draft);
  }
  removeUriSchemePlugin("http"); removeUriSchemePlugin("https"); removeUriSchemePlugin("file");
  const globalIndex = await loadJson(FIXTURE_INDEX);
  const bySchemaName = new Map(schemaFiles.map((filename) => [filename.replace(".schema.json", ""), path.join(ROOT, "schemas", filename)]));
  let total = 0, mismatches = 0;
  const seenIndexes = new Set();
  for (const fixtureSet of globalIndex.fixture_sets) {
    if (seenIndexes.has(fixtureSet.index_path)) continue;
    seenIndexes.add(fixtureSet.index_path);
    const index = await loadJson(path.join(ROOT, fixtureSet.index_path));
    for (const testCase of index.cases) {
      const schemaPath = bySchemaName.get(testCase.schema);
      if (!schemaPath) throw new Error(`fixture references unknown schema: ${testCase.schema}`);
      const schema = await loadJson(schemaPath);
      const wrapper = await loadJson(path.join(ROOT, fixtureSet.fixture_root, testCase.file));
      const instance = testCase.instance_field === null ? wrapper : wrapper[testCase.instance_field];
      const standard = await validate(schema.$id, instance);
      const actual = standard.valid && await profileValid(schema, instance, resources, schema.$id);
      total += 1;
      if (actual !== testCase.portable_valid) mismatches += 1;
    }
  }
  const standards = await loadJson(STANDARDS_INDEX);
  let standardsTotal = 0, standardsMismatches = 0;
  for (const selection of standards.selected) {
    const groups = await loadJson(path.join(STANDARDS_ROOT, selection.path));
    for (const groupIndex of selection.group_indices) {
      const group = groups[groupIndex];
      const groupUri = `urn:fkst:json-schema-test-suite:${selection.path}:${groupIndex}`;
      registerSchema(group.schema, groupUri, policy.draft);
      for (const testCase of group.tests) {
        const output = await validate(groupUri, testCase.data);
        standardsTotal += 1;
        if (output.valid !== testCase.valid) standardsMismatches += 1;
      }
    }
  }
  mismatches += standardsMismatches;
  const summary = { schema: "testing-node-schema-conformance-summary.v1", total, mismatches, standards_total: standardsTotal, standards_mismatches: standardsMismatches };
  process.stdout.write(`${JSON.stringify(summary)}\n`);
  return mismatches === 0 ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = await runConformance();
