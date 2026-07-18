'use strict';

const {
  artifactPath,
  authorizationArtifact,
  readJson,
  runtimeConfig,
} = require('./common');

function loadAuthorizationBundle(payload) {
  const start = payload.start;
  const config = runtimeConfig(payload);
  if (!start || typeof start !== 'object') throw new Error('start request is required');
  const profile = readJson(artifactPath(authorizationArtifact(config, start.profile_ref)));
  const approval = readJson(artifactPath(authorizationArtifact(config, start.approval_ref)));
  const receipt = readJson(artifactPath(authorizationArtifact(config, start.validation_receipt_ref)));
  return {
    profile,
    approval,
    receipt,
    context: {
      now: config.now,
      approval_ref: start.approval_ref,
      trusted_authorities: config.trusted_authorities || [],
    },
  };
}

module.exports = { loadAuthorizationBundle };
