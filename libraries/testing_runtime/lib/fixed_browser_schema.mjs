import fs from 'node:fs';
import { registerSchema, validate } from '../../../scripts/node_schema/vendor/node_modules/@hyperjump/json-schema/draft-2020-12/index.js';
import { profileValid } from '../../../scripts/node_schema/validate.mjs';

const resources = new Map();
for (const name of ['testing-case-result-set.v2', 'testing-case-result.v2', 'testing-observation.v1',
  'testing-assertion-result.v1', 'testing-evidence-manifest.v1', 'testing-result-reason.v1']) {
  const schema = JSON.parse(fs.readFileSync(new URL(`../../../schemas/${name}.schema.json`, import.meta.url), 'utf8'));
  resources.set(schema.$id, schema); registerSchema(schema);
}

export async function validateCanonical(result) {
  for (const instance of [result.case_result_set, result.evidence_manifest]) {
    const id = `https://chronoaiproject.github.io/fkst-packages-testing/schemas/${instance.schema}.schema.json`;
    const schema = resources.get(id);
    if (!schema || !(await validate(id, instance)).valid || !(await profileValid(schema, instance, resources, id))) {
      throw new Error('fixed-browser: canonical-schema-invalid');
    }
  }
}
