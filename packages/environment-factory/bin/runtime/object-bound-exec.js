'use strict';

const fs = require('fs');
const path = require('path');

const PYTHON = '/usr/bin/python3';
const EXEC_SOURCE = [
  'import os, stat, sys',
  'fd = int(sys.argv[1])',
  'expected_device, expected_inode = sys.argv[2], sys.argv[3]',
  'info = os.fstat(fd)',
  'if not stat.S_ISDIR(info.st_mode): raise SystemExit(126)',
  'if str(info.st_dev) != expected_device or str(info.st_ino) != expected_inode: raise SystemExit(126)',
  'argv = sys.argv[4:]',
  'if not argv: raise SystemExit(126)',
  'os.fchdir(fd)',
  'os.close(fd)',
  'os.execvpe(argv[0], argv, os.environ)',
].join('\n');

function sameObjectIdentity(left, right) {
  return Boolean(left && right
    && String(left.device) === String(right.device)
    && String(left.inode) === String(right.inode));
}

function openDirectoryAnchor(cwd, expectedIdentity) {
  if (!['darwin', 'linux'].includes(process.platform) || !fs.existsSync(PYTHON)) {
    throw new Error('object-bound process cwd is unsupported on this platform');
  }
  const target = path.resolve(cwd || process.cwd());
  const flags = fs.constants.O_RDONLY | (fs.constants.O_DIRECTORY || 0)
    | (fs.constants.O_NOFOLLOW || 0);
  const descriptor = fs.openSync(target, flags);
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isDirectory()) throw new Error('process cwd is not a directory');
    const identity = {
      device: String(stat.dev), inode: String(stat.ino), size: stat.size, mode: stat.mode,
    };
    if (expectedIdentity && !sameObjectIdentity(identity, expectedIdentity)) {
      throw new Error('process cwd object identity changed');
    }
    return { descriptor, identity, target };
  } catch (error) {
    fs.closeSync(descriptor);
    throw error;
  }
}

function objectBoundExec(anchor, argv, childDescriptor) {
  if (!anchor || !Number.isInteger(anchor.descriptor) || !anchor.identity
    || !Array.isArray(argv) || argv.length === 0
    || !Number.isInteger(childDescriptor) || childDescriptor < 3) {
    throw new Error('object-bound process launch is invalid');
  }
  return {
    command: PYTHON,
    argv: [
      '-I', '-c', EXEC_SOURCE, String(childDescriptor),
      anchor.identity.device, anchor.identity.inode, ...argv,
    ],
  };
}

function closeDirectoryAnchor(anchor) {
  if (!anchor || !Number.isInteger(anchor.descriptor)) return;
  try { fs.closeSync(anchor.descriptor); } catch (_error) {}
  anchor.descriptor = null;
}

module.exports = {
  closeDirectoryAnchor,
  objectBoundExec,
  openDirectoryAnchor,
  sameObjectIdentity,
};
