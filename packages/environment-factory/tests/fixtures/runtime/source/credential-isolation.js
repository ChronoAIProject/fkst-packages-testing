'use strict';

const path = require('path');

function assertCredentialIsolation() {
  for (const key of [
    'GH_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK', 'GIT_ASKPASS', 'SSH_ASKPASS',
    'FKST_WORKER_RUNTIME_ROOT',
    'FKST_OBJECT_BOUND_ALLOCATION_BROKER', 'FKST_OBJECT_BOUND_ALLOCATION_BROKER_SHA256',
    'FKST_OBJECT_BOUND_CLEANUP_BROKER', 'FKST_OBJECT_BOUND_CLEANUP_BROKER_SHA256',
  ]) {
    if (process.env[key]) throw new Error(`worker inherited forbidden authority: ${key}`);
  }
  const home = process.env.HOME || '';
  const nullDevice = process.platform === 'win32' ? 'NUL' : '/dev/null';
  if (path.basename(path.dirname(home)) !== 'worker-homes'
    || process.env.GIT_CONFIG_NOSYSTEM !== '1'
    || process.env.GIT_CONFIG_GLOBAL !== nullDevice
    || process.env.GIT_CONFIG_KEY_0 !== 'credential.helper'
    || process.env.GIT_CONFIG_VALUE_0 !== ''
    || process.env.GIT_CONFIG_KEY_1 !== 'core.askPass'
    || process.env.GIT_CONFIG_VALUE_1 !== ''
    || process.env.GIT_CONFIG_KEY_2 !== 'core.fsmonitor'
    || process.env.GIT_CONFIG_VALUE_2 !== 'false'
    || process.env.GIT_CONFIG_KEY_3 !== 'core.hooksPath'
    || process.env.GIT_CONFIG_VALUE_3 !== nullDevice
    || process.env.GIT_TERMINAL_PROMPT !== '0') {
    throw new Error('worker credential isolation controls are incomplete');
  }
}

module.exports = { assertCredentialIsolation };
