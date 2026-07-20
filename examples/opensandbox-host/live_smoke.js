import { readFile } from 'node:fs/promises';

import { FilesystemArtifactPublisher, FilesystemRunLedger } from './filesystem_host.js';
import { OpenSandboxHostAdapter } from './host_adapter.js';
import { createOpenSandboxSdk } from './opensandbox_sdk.js';

if (process.env.FKST_OPENSANDBOX_LIVE !== '1') {
  throw new Error('set FKST_OPENSANDBOX_LIVE=1 to acknowledge live sandbox creation and teardown');
}

const configPath = process.env.FKST_OPENSANDBOX_CONFIG;
const domain = process.env.OPEN_SANDBOX_DOMAIN;
if (!configPath || !domain) throw new Error('FKST_OPENSANDBOX_CONFIG and OPEN_SANDBOX_DOMAIN are required');

const config = JSON.parse(await readFile(configPath, 'utf8'));
const sdk = await createOpenSandboxSdk({
  domain,
  apiKey: process.env.OPEN_SANDBOX_API_KEY,
  useServerProxy: true,
  requestTimeoutSeconds: 60,
});
const ledger = new FilesystemRunLedger(process.env.FKST_OPENSANDBOX_LEDGER_ROOT ?? '.testing/opensandbox-host-ledger');
const adapter = new OpenSandboxHostAdapter({ sdk, ledger, publisher: new FilesystemArtifactPublisher() });
const receipt = await adapter.run(config);
process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
