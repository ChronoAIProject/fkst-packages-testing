const fs = require('fs');
const path = require('path');

const preparedRoot = path.join(process.cwd(), '.prepared');
const stateRoot = path.join(process.cwd(), 'state');

fs.mkdirSync(preparedRoot, { recursive: true });
fs.mkdirSync(stateRoot, { recursive: true });
fs.writeFileSync(path.join(preparedRoot, 'build.json'), '{"status":"complete"}\n');
fs.writeFileSync(
  path.join(stateRoot, 'inventory.json'),
  '{"sku":"SKU-001","on_hand":5,"reserved":0,"available":5}\n',
);
