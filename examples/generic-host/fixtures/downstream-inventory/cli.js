const fs = require('fs');
const path = require('path');

const preparedPath = path.join(process.cwd(), '.prepared', 'build.json');
const statePath = path.join(process.cwd(), 'state', 'inventory.json');

function fail(code, value) {
  process.stderr.write(`${JSON.stringify(value)}\n`);
  process.exit(code);
}

function readState() {
  if (!fs.existsSync(preparedPath)) fail(2, { error: 'fixture-not-prepared' });
  let state;
  try {
    state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  } catch (_error) {
    fail(2, { error: 'inventory-state-unavailable' });
  }
  const valid = state && Object.keys(state).sort().join(',') === 'available,on_hand,reserved,sku'
    && typeof state.sku === 'string'
    && Number.isInteger(state.on_hand) && state.on_hand >= 0
    && Number.isInteger(state.reserved) && state.reserved >= 0
    && Number.isInteger(state.available) && state.available >= 0
    && state.reserved + state.available === state.on_hand;
  if (!valid) fail(2, { error: 'inventory-state-malformed' });
  return state;
}

function writeState(state) {
  const temporaryPath = path.join(path.dirname(statePath), `.inventory.json.tmp-${process.pid}`);
  try {
    fs.writeFileSync(temporaryPath, `${JSON.stringify(state)}\n`, { flag: 'wx' });
    fs.renameSync(temporaryPath, statePath);
  } catch (_error) {
    try { fs.rmSync(temporaryPath, { force: true }); } catch (_cleanupError) {}
    fail(2, { error: 'inventory-state-persistence-failed' });
  }
}

const [command, sku, quantityText, ...extra] = process.argv.slice(2);
if (command !== 'reserve' || typeof sku !== 'string' || typeof quantityText !== 'string' || extra.length !== 0) {
  fail(2, { error: 'invalid-arguments' });
}
if (!/^[1-9][0-9]*$/.test(quantityText) || !Number.isSafeInteger(Number(quantityText))) {
  fail(2, { error: 'invalid-quantity' });
}

const state = readState();
if (sku !== state.sku) fail(3, { error: 'unknown-sku', sku });

const quantity = Number(quantityText);
if (quantity > state.available) {
  fail(4, { error: 'insufficient-available', sku, requested: quantity, available: state.available });
}

const next = {
  sku: state.sku,
  on_hand: state.on_hand,
  reserved: state.reserved + quantity,
  available: state.available - quantity,
};
writeState(next);
process.stdout.write(`${JSON.stringify(next)}\n`);
