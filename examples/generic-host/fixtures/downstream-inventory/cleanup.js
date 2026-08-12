const fs = require('fs');
const path = require('path');

for (const name of ['.prepared', 'state']) {
  fs.rmSync(path.join(process.cwd(), name), { recursive: true, force: true });
}
