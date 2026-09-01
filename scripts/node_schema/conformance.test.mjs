import assert from "node:assert/strict";
import test from "node:test";
import { runConformance } from "./validate.mjs";

test("vendored Draft 2020-12 engine validates the shared offline corpus", async () => {
  assert.equal(await runConformance(), 0);
});
