import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { runConformance, profileValid } from "./validate.mjs";

const matrix = JSON.parse(await readFile(new URL("../../packages/testing-design/tests/fixtures/generation/v1/boundary-matrix.json", import.meta.url), "utf8"));
test("UTF-8 profile rejects lone surrogates and accepts scalar strings", async () => {
  for (const schema of [{ "x-fkst-maxUtf8Bytes": 4 }, { format: "fkst-utf8-max-32" }]) {
    for (const sample of matrix.unicode_scalars) {
      assert.equal(await profileValid(schema, String.fromCodePoint(...sample.codepoints), new Map(), "https://example.invalid/"), sample.valid);
    }
    assert.equal(await profileValid(schema, JSON.parse('"\\ud83d\\ude00"'), new Map(), "https://example.invalid/"), true);
  }
  assert.equal(await profileValid({ "x-fkst-maxUtf8Bytes": 3 }, "😀", new Map(), "https://example.invalid/"), false);
});

test("vendored Draft 2020-12 engine validates the shared offline corpus", async () => {
  assert.equal(await runConformance(), 0);
});
