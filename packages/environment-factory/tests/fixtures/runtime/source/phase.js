'use strict';

const fs = require('fs');
const path = require('path');
const protocol = require('fixture-protocol');

const phase = process.argv[2];
const targetPort = Number(process.argv[3]);
const fixtureRoot = path.join(process.cwd(), '.fixture');

async function main() {
  if (phase === 'build') {
    fs.mkdirSync(fixtureRoot, { recursive: true });
    fs.writeFileSync(path.join(fixtureRoot, 'build'), `${protocol.packageName}\n`);
    return;
  }
  if (phase === 'migrate' || phase === 'seed') {
    const response = await protocol.requestJson(targetPort, `/${phase}`, { method: 'POST' });
    if (response.status !== 204) process.exit(32);
    return;
  }
  if (phase === 'verify') {
    if (!fs.existsSync(path.join(fixtureRoot, 'build'))) process.exit(33);
    const response = await protocol.requestJson(targetPort, '/state');
    const state = response.json;
    if (response.status !== 200 || state.migrated !== true || state.seeded !== true
      || state.message !== 'seeded-through-sql' || state.via !== 'middleware'
      || state.protocol_package !== protocol.packageName) process.exit(34);
    return;
  }
  if (phase === 'cleanup') {
    protocol.writeEvidence(`${process.argv[3]}-cleanup-command.json`, {
      phase,
      role: process.argv[3],
      protocol_package: protocol.packageName,
    });
    return;
  }
  process.exit(35);
}

main().catch(() => process.exit(36));
