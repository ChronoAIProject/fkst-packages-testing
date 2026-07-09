#!/usr/bin/env node
'use strict';

const observer = require('../lib/cdp_observer');

function take(argv, index, name) {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith('--')) throw new Error(`${name} requires a value`);
  return value;
}

function parseArgs(argv) {
  const args = {
    blockPrefixes: [],
    blockSegments: [],
    selfTest: false,
  };
  for (let index = 2; index < argv.length; index += 1) {
    const item = argv[index];
    if (item === '--self-test') args.selfTest = true;
    else if (item === '--base-url') args.baseUrl = take(argv, index++, item);
    else if (item === '--cdp-url') args.cdpUrl = take(argv, index++, item);
    else if (item === '--json-out') args.jsonOut = take(argv, index++, item);
    else if (item === '--lua-out') args.luaOut = take(argv, index++, item);
    else if (item === '--artifact-root') args.artifactRoot = take(argv, index++, item);
    else if (item === '--id-prefix') args.idPrefix = take(argv, index++, item);
    else if (item === '--manifest-schema') args.manifestSchema = take(argv, index++, item);
    else if (item === '--evidence-schema') args.evidenceSchema = take(argv, index++, item);
    else if (item === '--observation-limit') args.observationLimit = take(argv, index++, item);
    else if (item === '--page-limit') args.pageLimit = take(argv, index++, item);
    else if (item === '--block-prefix') args.blockPrefixes.push(take(argv, index++, item));
    else if (item === '--block-segment') args.blockSegments.push(take(argv, index++, item));
    else throw new Error(`unknown argument: ${item}`);
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.selfTest) {
    await observer.runSelfTest();
    console.log('fkst-cdp-observer: self-test passed');
    return;
  }
  const payload = await observer.run(args);
  console.log(`fkst-cdp-observer: wrote ${payload.observation_count} observations`);
}

main().catch((err) => {
  console.error(`fkst-cdp-observer: ${err.message}`);
  process.exit(1);
});
