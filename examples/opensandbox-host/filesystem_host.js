import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';

function receiptName(dedupKey) {
  return `${createHash('sha256').update(dedupKey).digest('hex')}.json`;
}

async function atomicWrite(filePath, bytes) {
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.tmp-${process.pid}-${process.hrtime.bigint()}`;
  await writeFile(temporary, bytes, { flag: 'wx' });
  await rename(temporary, filePath);
}

export class FilesystemRunLedger {
  constructor(root) {
    this.root = path.resolve(root);
  }

  receiptPath(dedupKey) {
    return path.join(this.root, 'receipts', receiptName(dedupKey));
  }

  async load(dedupKey) {
    try {
      return JSON.parse(await readFile(this.receiptPath(dedupKey), 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error;
    }
  }

  async save(receipt) {
    await atomicWrite(this.receiptPath(receipt.dedup_key), `${JSON.stringify(receipt)}\n`);
  }

  async append(status) {
    const encoded = `${JSON.stringify(status)}\n`;
    if (Buffer.byteLength(encoded) > 2048) throw new Error('lifecycle status exceeds bounded ledger entry size');
    const eventRoot = path.join(this.root, 'events', receiptName(status.dedup_key).replace(/\.json$/u, ''));
    const eventPath = path.join(eventRoot, `${Date.now()}-${process.hrtime.bigint()}.json`);
    await atomicWrite(eventPath, encoded);
  }
}

export class FilesystemArtifactPublisher {
  async publish({ destination, relative_path: relativePath, bytes, sha256, trace_id: traceId, dedup_key: dedupKey }) {
    if (destination.kind !== 'filesystem') throw new Error('filesystem publisher requires a filesystem destination');
    if (!relativePath || path.isAbsolute(relativePath) || relativePath.split(/[\\/]/u).includes('..')) {
      throw new Error('artifact relative path is unsafe');
    }
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (actual !== sha256) throw new Error('artifact digest mismatch');
    const root = path.resolve(destination.root, dedupKey);
    const target = path.resolve(root, relativePath);
    if (target !== root && !target.startsWith(`${root}${path.sep}`)) throw new Error('artifact path escapes destination root');
    await atomicWrite(target, bytes);
    return { kind: 'artifact', ref: target, sha256, trace_id: traceId };
  }
}
