'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const SCHEMAS = {
  repositoryAnalysis: 'testing-design.repository-analysis.v1',
  requirementsIndex: 'testing-design.requirements-index.v1',
  traceabilitySeed: 'testing-design.traceability-seed.v1',
  artifactReference: 'testing-design.artifact-reference.v1',
  contextReference: 'testing-design.context-reference.v1',
};
const ANALYZER_REVISION = 'testing-design-analyzer.v1';
const MAX_INPUT_BYTES = 256 * 1024;
const MAX_REPOSITORY_BYTES = 2 * 1024 * 1024;
const MAX_FILES = 256;
const MAX_ITEMS = 128;
const MAX_MAPPINGS = 256;
const TEXT_EXTENSIONS = new Set([
  '.c', '.cc', '.cpp', '.cs', '.css', '.go', '.gql', '.graphql', '.h', '.hpp', '.html',
  '.java', '.js', '.jsx', '.json', '.lua', '.md', '.php', '.py', '.rb', '.rs', '.rst',
  '.sh', '.sql', '.toml', '.ts', '.tsx', '.txt', '.xml', '.yaml', '.yml',
]);

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function stableStringify(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  if (typeof value !== 'object') throw new Error('testing-design: canonical-json-unsupported-value');
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
}

function artifactBody(value) {
  return `${stableStringify(value)}\n`;
}

function bounded(value, limit = 240) {
  return String(value || '').replace(/[\x00-\x1f\x7f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, limit);
}

function safeId(prefix, value) {
  return `${prefix}-${sha256(String(value)).slice(0, 16)}`;
}

function pushBounded(list, value, key) {
  if (list.length >= MAX_ITEMS) return;
  if (key !== undefined && list.some((item) => item[key] === value[key])) return;
  list.push(value);
}

function assertArtifactRoot(root) {
  if (typeof root !== 'string' || !root.startsWith('.testing/runs/') || root.includes('..')
    || root.includes('\\') || /[\x00-\x1f\x7f]/.test(root)) {
    throw new Error('testing-design: unsafe-artifact-root');
  }
}

function git(workspace, args, maxBuffer = 4 * 1024 * 1024) {
  const result = spawnSync('git', ['-C', workspace, ...args], {
    encoding: 'utf8',
    maxBuffer,
    shell: false,
  });
  if (result.status !== 0) {
    throw new Error(`testing-design: git-inspection-failed: ${bounded(result.stderr, 512)}`);
  }
  return result.stdout;
}

function resolvePointer(pointer, workspace) {
  if (!pointer || typeof pointer.kind !== 'string' || typeof pointer.ref !== 'string') {
    return { supported: false, reason: 'malformed-pointer' };
  }
  if (pointer.kind === 'artifact' || pointer.kind === 'file' || pointer.kind === 'browser-evidence') {
    return { supported: true, filePath: path.resolve(pointer.ref) };
  }
  if (pointer.kind === 'workspace-file') {
    const root = fs.realpathSync(workspace);
    const candidate = path.resolve(root, pointer.ref);
    if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
      return { supported: false, reason: 'pointer-leaves-workspace' };
    }
    let resolved;
    try { resolved = fs.realpathSync(candidate); } catch (_error) {
      return { supported: true, filePath: candidate };
    }
    if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
      return { supported: false, reason: 'pointer-leaves-workspace' };
    }
    return { supported: true, filePath: resolved };
  }
  return { supported: false, reason: `unsupported-pointer-kind:${bounded(pointer.kind, 80)}` };
}

function pointerSummary(pointer, digest) {
  return { kind: pointer.kind, ref: pointer.ref, sha256: digest };
}

function verifyFile(pointer, expectedDigest, workspace, maxBytes) {
  const resolved = resolvePointer(pointer, workspace);
  if (!resolved.supported) return { ok: false, unsupported: true, reason: resolved.reason };
  let stat;
  try { stat = fs.statSync(resolved.filePath); } catch (_error) {
    return { ok: false, reason: 'unreadable-input' };
  }
  if (!stat.isFile()) return { ok: false, reason: 'pointer-is-not-file' };
  if (stat.size > maxBytes) return { ok: false, reason: 'oversized-input', size_bytes: stat.size };
  let body;
  try { body = fs.readFileSync(resolved.filePath); } catch (_error) {
    return { ok: false, reason: 'unreadable-input' };
  }
  const actual = sha256(body);
  if (actual !== expectedDigest) return { ok: false, reason: 'digest-mismatch', actual_sha256: actual };
  return { ok: true, body, filePath: resolved.filePath, sha256: actual };
}

function verifyApproval(pointer, digest, workspace, expected) {
  const verified = verifyFile(pointer, digest, workspace, MAX_INPUT_BYTES);
  if (!verified.ok) throw new Error(`testing-design: approval-verification-failed: ${verified.reason}`);
  let approval;
  try { approval = JSON.parse(verified.body.toString('utf8')); } catch (_error) {
    throw new Error('testing-design: approval-invalid-json');
  }
  if (stableStringify(approval) !== stableStringify({ schema: 'testing-design.approval.v1', ...expected })) {
    throw new Error('testing-design: approval-subject-mismatch');
  }
  return verified;
}

function repositoryApprovalSubject(repository) {
  return {
    subject_kind: 'repository', repository_url: repository.url, workspace_ref: repository.workspace_ref,
    target_commit_sha: repository.commit_sha, baseline_commit_sha: repository.baseline_commit_sha,
  };
}

function inputApprovalSubject(input) {
  return {
    subject_kind: 'input', input_kind: input.kind, source_ref: input.source_ref,
    revision: input.revision, content_sha256: input.content_sha256,
  };
}

function browserApprovalSubject(evidence) {
  return {
    subject_kind: 'browser-evidence', artifact_pointer: evidence.artifact_pointer,
    artifact_digest: evidence.artifact_digest,
  };
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index].startsWith('--')) values[argv[index].slice(2)] = argv[index + 1];
  }
  return values;
}

function changedFiles(workspace, baseline, target) {
  return git(workspace, ['diff', '--name-status', '--find-renames', baseline, target])
    .split('\n').filter(Boolean).slice(0, MAX_ITEMS).map((line) => {
      const fields = line.split('\t');
      return {
        status: bounded(fields[0], 16),
        path: bounded(fields[fields.length - 1], 512),
        previous_path: fields.length > 2 ? bounded(fields[1], 512) : undefined,
      };
    }).map((item) => {
      if (item.previous_path === undefined) delete item.previous_path;
      return item;
    });
}

function trackedFiles(workspace, target) {
  return git(workspace, ['ls-tree', '-r', '--name-only', target])
    .split('\n').filter(Boolean).sort().slice(0, MAX_FILES);
}

function readBlob(workspace, target, filePath, remainingBytes) {
  const extension = path.extname(filePath).toLowerCase();
  const basename = path.basename(filePath).toLowerCase();
  if (!TEXT_EXTENSIONS.has(extension) && !['dockerfile', 'makefile'].includes(basename)) {
    return { supported: false, reason: 'unsupported-repository-file' };
  }
  const size = Number(git(workspace, ['cat-file', '-s', `${target}:${filePath}`], 1024).trim());
  if (!Number.isFinite(size) || size < 0 || size > Math.min(MAX_INPUT_BYTES, remainingBytes)) {
    return { supported: false, reason: 'oversized-repository-file', size_bytes: size };
  }
  const result = spawnSync('git', ['-C', workspace, 'show', `${target}:${filePath}`], {
    encoding: 'utf8', maxBuffer: MAX_INPUT_BYTES + 1024, shell: false,
  });
  if (result.status !== 0 || result.stdout.includes('\0')) return { supported: false, reason: 'unreadable-repository-file' };
  return { supported: true, text: result.stdout, size_bytes: Buffer.byteLength(result.stdout) };
}

function injectionSignals(text, source) {
  const patterns = [
    ['ignore-prior-instructions', /ignore\s+(all\s+)?(previous|prior)\s+instructions?/i],
    ['authority-spoofing', /(system|developer)\s+(message|prompt|instruction)/i],
    ['execution-request', /(run|execute)\s+(this\s+)?(command|script|shell)/i],
    ['model-role-instruction', /you\s+are\s+(chatgpt|claude|an?\s+ai)/i],
  ];
  const findings = [];
  text.split(/\r?\n/).forEach((line, index) => {
    for (const [classification, pattern] of patterns) {
      if (pattern.test(line)) {
        pushBounded(findings, { classification, source_pointer: source, line: index + 1 }, 'classification');
      }
    }
  });
  return findings;
}

function routeValues(text) {
  const routes = [];
  const patterns = [
    /\b(?:app|router|server)\s*\.\s*(?:get|post|put|patch|delete|use)\s*\(\s*['"`]([^'"`]+)['"`]/gi,
    /@(?:app|router)\.(?:get|post|put|patch|delete)\s*\(\s*['"`]([^'"`]+)['"`]/gi,
    /\bpath\s*[:=]\s*['"`]([^'"`]+)['"`]/gi,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const value = bounded(match[1], 240);
      if (value.startsWith('/')) pushBounded(routes, value);
    }
  }
  return routes;
}

function apiValues(text) {
  const values = [];
  const pattern = /\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+((?:\/|https?:\/\/)[^\s'"`]+)/gi;
  let match;
  while ((match = pattern.exec(text)) !== null) pushBounded(values, `${match[1].toUpperCase()} ${bounded(match[2], 220)}`);
  return values;
}

function pathValues(text) {
  const values = [];
  const pattern = /(^|[\s`'"(])\/(?!\/)([A-Za-z0-9_:{.}-]+(?:\/[A-Za-z0-9_:{.}-]+)*)/g;
  let match;
  while ((match = pattern.exec(text)) !== null) pushBounded(values, `/${match[2]}`);
  return values;
}

function symbolsFor(text, filePath) {
  const values = [];
  const patterns = [
    ['function', /\b(?:function|def|fn)\s+([A-Za-z_$][\w$]*)/g],
    ['class', /\bclass\s+([A-Za-z_$][\w$]*)/g],
    ['export', /\bexport\s+(?:default\s+)?(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/g],
  ];
  for (const [kind, pattern] of patterns) {
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const line = text.slice(0, match.index).split('\n').length;
      pushBounded(values, {
        id: safeId('signal', `${kind}:${filePath}:${match[1]}:${line}`),
        kind,
        name: bounded(match[1], 180),
        path: filePath,
        line,
        evidence_pointer: { kind: 'repository-blob', ref: `${filePath}@${line}` },
      }, 'id');
    }
  }
  return values;
}

function dependencyValues(text, filePath) {
  const values = [];
  if (path.basename(filePath) === 'package.json') {
    try {
      const parsed = JSON.parse(text);
      for (const section of ['dependencies', 'devDependencies', 'peerDependencies']) {
        for (const name of Object.keys(parsed[section] || {}).sort()) {
          pushBounded(values, { name: bounded(name, 180), source_path: filePath, kind: section }, 'name');
        }
      }
    } catch (_error) {}
  }
  const pattern = /\b(?:require\s*\(\s*['"]([^'"]+)['"]|from\s+['"]([^'"]+)['"]|import\s+['"]([^'"]+)['"])/g;
  let match;
  while ((match = pattern.exec(text)) !== null) {
    const name = bounded(match[1] || match[2] || match[3], 180);
    if (name && !name.startsWith('.')) pushBounded(values, { name, source_path: filePath, kind: 'import' }, 'name');
  }
  return values;
}

function cliValues(text, filePath) {
  const values = [];
  const patterns = [
    /\.command\s*\(\s*['"`]([^'"`]+)['"`]/g,
    /add_parser\s*\(\s*['"`]([^'"`]+)['"`]/g,
    /Command::new\s*\(\s*['"`]([^'"`]+)['"`]/g,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(text)) !== null) {
      pushBounded(values, { command: bounded(match[1], 180), source_path: filePath }, 'command');
    }
  }
  return values;
}

function isTestPath(filePath) {
  return /(^|\/)(test|tests|spec|specs|__tests__)(\/|$)|(?:_test|\.test|\.spec)\.[^.]+$/i.test(filePath);
}

function repositorySignals(workspace, target, files) {
  const analysis = {
    relevant_symbols: [], routes: [], apis: [], cli_commands: [], dependency_signals: [], existing_tests: [],
    untrusted_instruction_signals: [], limitations: [], modules: [],
  };
  let consumed = 0;
  const moduleSet = new Set();
  for (const filePath of files) {
    if (consumed >= MAX_REPOSITORY_BYTES) break;
    const blob = readBlob(workspace, target, filePath, MAX_REPOSITORY_BYTES - consumed);
    if (!blob.supported) {
      if (blob.reason === 'oversized-repository-file') pushBounded(analysis.limitations, `Skipped oversized repository file: ${filePath}`);
      continue;
    }
    consumed += blob.size_bytes;
    const text = blob.text;
    for (const item of symbolsFor(text, filePath)) pushBounded(analysis.relevant_symbols, item, 'id');
    for (const value of routeValues(text)) pushBounded(analysis.routes, { id: safeId('route', value), route: value, source_path: filePath }, 'id');
    for (const value of apiValues(text)) pushBounded(analysis.apis, { id: safeId('api', value), surface: value, source_path: filePath }, 'id');
    for (const value of cliValues(text, filePath)) pushBounded(analysis.cli_commands, value, 'command');
    for (const value of dependencyValues(text, filePath)) pushBounded(analysis.dependency_signals, value, 'name');
    if (isTestPath(filePath)) pushBounded(analysis.existing_tests, { path: filePath, evidence_pointer: { kind: 'repository-blob', ref: `${target}:${filePath}` } }, 'path');
    for (const finding of injectionSignals(text, { kind: 'repository-blob', ref: `${target}:${filePath}` })) {
      pushBounded(analysis.untrusted_instruction_signals, finding, 'classification');
    }
    const segment = filePath.split('/')[0] || 'repository-root';
    moduleSet.add(segment);
  }
  if (files.length >= MAX_FILES) analysis.limitations.push(`Repository scan bounded to ${MAX_FILES} tracked files.`);
  if (consumed >= MAX_REPOSITORY_BYTES) analysis.limitations.push(`Repository scan bounded to ${MAX_REPOSITORY_BYTES} bytes.`);
  analysis.modules = [...moduleSet].sort().slice(0, 64).map((name) => ({
    id: safeId('module', name), name: bounded(name, 180), evidence_pointer: { kind: 'repository-tree', ref: `${target}:${name}` },
  }));
  return analysis;
}

function sourceRecord(input, status, reason) {
  const record = {
    kind: input.kind,
    source_pointer: { kind: input.source_ref.kind, ref: input.source_ref.ref },
    source_sha256: input.content_sha256,
    revision: input.revision,
    status,
  };
  if (reason) record.reason = reason;
  return record;
}

function requirementSections(text, input) {
  const requirements = [];
  const lines = text.split(/\r?\n/);
  let current = null;
  function commit() {
    if (!current || requirements.length >= MAX_ITEMS) return;
    const summary = bounded(current.summary, 240);
    if (!summary) return;
    const explicit = summary.match(/\b(?:REQ|AC)-[A-Za-z0-9._-]+\b/i);
    requirements.push({
      id: explicit ? explicit[0].toUpperCase() : safeId('REQ', `${input.source_ref.ref}:${current.line}:${summary}`),
      summary,
      acceptance_criteria: current.criteria.slice(0, 8),
      source_pointer: { kind: input.source_ref.kind, ref: input.source_ref.ref },
      source_sha256: input.content_sha256,
      source_line: current.line,
      untrusted_data: true,
    });
  }
  lines.forEach((line, index) => {
    const heading = line.match(/^#{1,6}\s+(.+)/) || line.match(/^\s*((?:REQ|AC)-[A-Za-z0-9._-]+)\s*[:\-]\s*(.+)/i);
    if (heading) {
      commit();
      current = { summary: heading[2] ? `${heading[1]} ${heading[2]}` : heading[1], line: index + 1, criteria: [] };
      return;
    }
    if (!current && /^\s*(?:requirement|must|should)\b/i.test(line)) {
      current = { summary: line, line: index + 1, criteria: [] };
    }
    if (current && /^\s*(?:[-*]\s+)?(?:acceptance|given\b|when\b|then\b|must\b|should\b)/i.test(line)) {
      const criterion = bounded(line.replace(/^\s*[-*]\s*/, ''), 240);
      if (criterion && current.criteria.length < 8) current.criteria.push(criterion);
    }
  });
  commit();
  if (requirements.length === 0) {
    const candidate = lines.find((line) => /^\s*(?:must|should|requirement)\b/i.test(line));
    if (candidate) {
      requirements.push({
        id: safeId('REQ', `${input.source_ref.ref}:1:${candidate}`), summary: bounded(candidate, 240),
        acceptance_criteria: [], source_pointer: { kind: input.source_ref.kind, ref: input.source_ref.ref },
        source_sha256: input.content_sha256, source_line: 1, untrusted_data: true,
      });
    }
  }
  return requirements;
}

function schemaSignals(text, input) {
  const routes = [];
  try {
    const parsed = JSON.parse(text);
    for (const route of Object.keys(parsed.paths || {}).sort()) {
      for (const method of Object.keys(parsed.paths[route] || {}).sort()) {
        if (/^(get|post|put|patch|delete|head|options)$/i.test(method)) {
          pushBounded(routes, { id: safeId('api', `${method}:${route}`), surface: `${method.toUpperCase()} ${route}`, source_path: input.source_ref.ref }, 'id');
        }
      }
    }
  } catch (_error) {
    for (const route of routeValues(text)) pushBounded(routes, { id: safeId('route', route), surface: route, source_path: input.source_ref.ref }, 'id');
    for (const api of apiValues(text)) pushBounded(routes, { id: safeId('api', api), surface: api, source_path: input.source_ref.ref }, 'id');
  }
  return routes;
}

function inputAnalysis(request, workspace, repository) {
  const index = {
    schema: SCHEMAS.requirementsIndex,
    analyzer_revision: ANALYZER_REVISION,
    analysis_key: null,
    requirements: [],
    requirement_count: 0,
    sources: [],
    unreadable_inputs: [],
    unsupported_inputs: [],
    untrusted_instruction_signals: [],
    limitations: [],
  };
  const extraApis = [];
  const extraTests = [];
  const requirementRoutes = new Set();
  for (const input of request.inputs || []) {
    try {
      verifyApproval(input.approval_ref, input.approval_sha256, workspace, inputApprovalSubject(input));
    } catch (error) {
      const reason = String(error && error.message || error).includes('approval-subject-mismatch')
        ? 'approval-subject-mismatch' : 'approval-unreadable';
      pushBounded(index.unreadable_inputs, sourceRecord(input, 'unreadable', reason));
      pushBounded(index.sources, sourceRecord(input, 'unreadable', reason));
      continue;
    }
    const verified = verifyFile(input.source_ref, input.content_sha256, workspace, MAX_INPUT_BYTES);
    if (!verified.ok) {
      const target = verified.unsupported ? index.unsupported_inputs : index.unreadable_inputs;
      pushBounded(target, sourceRecord(input, verified.unsupported ? 'unsupported' : 'unreadable', verified.reason));
      pushBounded(index.sources, sourceRecord(input, verified.unsupported ? 'unsupported' : 'unreadable', verified.reason));
      continue;
    }
    const extension = path.extname(verified.filePath).toLowerCase();
    if (!TEXT_EXTENSIONS.has(extension)) {
      pushBounded(index.unsupported_inputs, sourceRecord(input, 'unsupported', 'unsupported-content-type'));
      pushBounded(index.sources, sourceRecord(input, 'unsupported', 'unsupported-content-type'));
      continue;
    }
    const text = verified.body.toString('utf8');
    pushBounded(index.sources, sourceRecord(input, 'readable'));
    for (const finding of injectionSignals(text, { kind: input.source_ref.kind, ref: input.source_ref.ref })) {
      pushBounded(index.untrusted_instruction_signals, finding, 'classification');
    }
    if (input.kind === 'requirements' || input.kind === 'design') {
      for (const requirement of requirementSections(text, input)) {
        pushBounded(index.requirements, requirement, 'id');
        for (const route of pathValues(`${requirement.summary}\n${requirement.acceptance_criteria.join('\n')}`)) requirementRoutes.add(route);
      }
    } else if (input.kind === 'api-schema') {
      for (const api of schemaSignals(text, input)) pushBounded(extraApis, api, 'id');
    } else if (input.kind === 'existing-tests') {
      text.split(/\r?\n/).map((line) => bounded(line, 512)).filter(Boolean).forEach((testPath) => {
        pushBounded(extraTests, { path: testPath, evidence_pointer: pointerSummary(input.source_ref, input.content_sha256) }, 'path');
      });
    }
  }
  index.requirement_count = index.requirements.length;
  if (!index.sources.some((source) => (source.kind === 'requirements' || source.kind === 'design') && source.status === 'readable')) {
    index.limitations.push('No readable approved requirements or design input was available; no product behavior was inferred.');
  }
  repository.apis.push(...extraApis.slice(0, Math.max(0, MAX_ITEMS - repository.apis.length)));
  repository.existing_tests.push(...extraTests.slice(0, Math.max(0, MAX_ITEMS - repository.existing_tests.length)));
  return { index, requirementRoutes };
}

function browserAnalysis(request, workspace) {
  const result = { status: 'not-provided', routes: new Set(), apis: new Set(), pointer: null, reason: null };
  const evidence = request.browser_evidence;
  if (!evidence) return result;
  result.pointer = { kind: 'artifact', ref: evidence.artifact_pointer, sha256: evidence.artifact_digest };
  try {
    verifyApproval(evidence.approval_ref, evidence.approval_sha256, workspace, browserApprovalSubject(evidence));
  } catch (error) {
    result.status = 'unreadable';
    result.reason = String(error && error.message || error).includes('approval-subject-mismatch')
      ? 'approval-subject-mismatch' : 'approval-unreadable';
    return result;
  }
  const verified = verifyFile({ kind: 'browser-evidence', ref: evidence.artifact_pointer }, evidence.artifact_digest, workspace, MAX_INPUT_BYTES);
  if (!verified.ok) { result.status = 'unreadable'; result.reason = verified.reason; return result; }
  let parsed;
  try { parsed = JSON.parse(verified.body.toString('utf8')); } catch (_error) {
    result.status = 'unsupported'; result.reason = 'unsupported-browser-evidence'; return result;
  }
  const collectRoute = (value) => { const route = bounded(value, 240); if (route.startsWith('/')) result.routes.add(route); };
  for (const route of parsed.routes || []) collectRoute(typeof route === 'string' ? route : route.route);
  for (const item of parsed.observations || []) collectRoute(item.route);
  for (const item of parsed.modules || []) collectRoute(item.route);
  for (const item of parsed.apis || []) {
    const value = bounded(typeof item === 'string' ? item : item.surface, 240);
    if (value) result.apis.add(value);
  }
  result.status = 'readable';
  return result;
}

function designGaps(repository, requirements, browser) {
  const gaps = [];
  const codeRoutes = new Set(repository.routes.map((item) => item.route));
  const browserRoutes = browser.routes;
  for (const route of requirements) {
    if (!codeRoutes.has(route)) pushBounded(gaps, {
      id: safeId('gap', `requirements-code:${route}`), classification: 'requirements-code-disagreement',
      subject: route, evidence_sources: ['requirements', 'repository'],
    }, 'id');
    if (browser.status === 'readable' && !browserRoutes.has(route)) pushBounded(gaps, {
      id: safeId('gap', `requirements-browser:${route}`), classification: 'requirements-browser-disagreement',
      subject: route, evidence_sources: ['requirements', 'browser'],
    }, 'id');
  }
  if (browser.status === 'readable') {
    for (const route of browserRoutes) {
      if (!codeRoutes.has(route)) pushBounded(gaps, {
        id: safeId('gap', `browser-code:${route}`), classification: 'browser-code-disagreement',
        subject: route, evidence_sources: ['browser', 'repository'],
      }, 'id');
    }
    for (const route of codeRoutes) {
      if (!browserRoutes.has(route)) pushBounded(gaps, {
        id: safeId('gap', `code-browser:${route}`), classification: 'code-browser-disagreement',
        subject: route, evidence_sources: ['repository', 'browser'],
      }, 'id');
    }
  } else if (browser.status !== 'not-provided') {
    pushBounded(gaps, {
      id: safeId('gap', `browser:${browser.reason}`), classification: 'browser-evidence-unreadable',
      subject: browser.reason, evidence_sources: ['browser'],
    }, 'id');
  }
  return gaps;
}

function traceability(requirements, repository, gaps, request) {
  const signals = [
    ...repository.routes.map((item) => ({ id: item.id, label: item.route, kind: 'route', pointer: { kind: 'repository-path', ref: item.source_path } })),
    ...repository.apis.map((item) => ({ id: item.id, label: item.surface, kind: 'api', pointer: { kind: 'repository-path', ref: item.source_path } })),
    ...repository.cli_commands.map((item) => ({ id: safeId('cli', item.command), label: item.command, kind: 'cli', pointer: { kind: 'repository-path', ref: item.source_path } })),
    ...repository.existing_tests.map((item) => ({ id: safeId('test', item.path), label: item.path, kind: 'existing-test', pointer: item.evidence_pointer })),
  ].filter((item) => typeof item.label === 'string' && item.label !== '').slice(0, MAX_ITEMS);
  const modules = repository.discovered_modules || [];
  const mappings = [];
  const unmapped = [];
  for (const requirement of requirements.requirements) {
    const terms = new Set(requirement.summary.toLowerCase().split(/[^a-z0-9/_-]+/).filter((term) => term.length >= 4));
    const matches = signals.filter((signal) => typeof signal.label === 'string'
      && [...terms].some((term) => signal.label.toLowerCase().includes(term))).slice(0, 4);
    if (matches.length === 0) {
      pushBounded(unmapped, { requirement_id: requirement.id, reason: 'no-repository-signal' }, 'requirement_id');
      continue;
    }
    for (const signal of matches) {
      if (mappings.length >= MAX_MAPPINGS) break;
      const module = modules.find((item) => signal.pointer && signal.pointer.ref && signal.pointer.ref.startsWith(item.name)) || modules[0];
      mappings.push({
        requirement_id: requirement.id,
        repository_signal_id: signal.id,
        repository_signal_kind: signal.kind,
        module_id: module ? module.id : null,
        candidate_objective: bounded(`Verify ${requirement.id} against evidence-backed ${signal.kind} ${signal.label}.`, 240),
        evidence_pointers: [requirement.source_pointer, signal.pointer].filter(Boolean),
      });
    }
  }
  return {
    schema: SCHEMAS.traceabilitySeed,
    analyzer_revision: ANALYZER_REVISION,
    analysis_key: null,
    repository: {
      url: request.repository.url,
      target_commit_sha: request.repository.commit_sha,
      baseline_commit_sha: request.repository.baseline_commit_sha,
    },
    discovered_modules: modules,
    repository_signals: signals,
    mappings,
    mapping_count: mappings.length,
    unmapped_requirements: unmapped,
    design_gaps: gaps,
    design_gap_count: gaps.length,
    limitations: ['Candidate objectives are seeded only from recorded evidence and do not authorize execution.'],
  };
}

function immutableArtifacts(root, documents) {
  fs.mkdirSync(root, { recursive: true });
  const states = documents.map((item) => {
    const body = artifactBody(item.document);
    const pointer = `${root}/${item.filename}`;
    if (!fs.existsSync(pointer)) return { ...item, body, pointer, exists: false };
    const existing = fs.readFileSync(pointer, 'utf8');
    if (existing !== body) throw new Error(`testing-design: immutable-artifact-conflict: ${pointer}`);
    return { ...item, body, pointer, exists: true };
  });
  for (const state of states.filter((item) => !item.exists)) {
    try { fs.writeFileSync(state.pointer, state.body, { flag: 'wx', mode: 0o600 }); } catch (error) {
      if (error.code !== 'EEXIST' || fs.readFileSync(state.pointer, 'utf8') !== state.body) throw error;
    }
  }
  const references = {};
  for (const state of states) references[state.name] = {
    schema: SCHEMAS.artifactReference,
    artifact_schema: state.document.schema,
    artifact_pointer: state.pointer,
    artifact_digest: sha256(Buffer.from(state.body)),
  };
  return { replayed: states.every((item) => item.exists), references };
}

function analyze(request) {
  assertArtifactRoot(request.artifact_root);
  if (!request.repository || !request.repository.workspace_ref || request.repository.workspace_ref.kind !== 'workspace') {
    throw new Error('testing-design: approved-workspace-required');
  }
  const workspace = fs.realpathSync(path.resolve(request.repository.workspace_ref.ref));
  verifyApproval(
    request.repository.approval_ref,
    request.repository.approval_sha256,
    workspace,
    repositoryApprovalSubject(request.repository),
  );
  const head = git(workspace, ['rev-parse', 'HEAD']).trim();
  if (head !== request.repository.commit_sha) throw new Error('testing-design: target-worktree-commit-mismatch');
  if (git(workspace, ['status', '--porcelain', '--untracked-files=all']).trim() !== '') {
    throw new Error('testing-design: target-worktree-not-immutable');
  }
  git(workspace, ['cat-file', '-e', `${request.repository.commit_sha}^{commit}`]);
  git(workspace, ['cat-file', '-e', `${request.repository.baseline_commit_sha}^{commit}`]);

  const analysisKey = sha256(stableStringify({
    analyzer_revision: ANALYZER_REVISION,
    repository: request.repository,
    inputs: request.inputs || [],
    browser_evidence: request.browser_evidence || null,
  }));
  const changed = changedFiles(workspace, request.repository.baseline_commit_sha, request.repository.commit_sha);
  const files = trackedFiles(workspace, request.repository.commit_sha);
  const signals = repositorySignals(workspace, request.repository.commit_sha, files);
  const repository = {
    schema: SCHEMAS.repositoryAnalysis,
    analyzer_revision: ANALYZER_REVISION,
    analysis_key: analysisKey,
    repository: {
      url: request.repository.url,
      target_commit_sha: request.repository.commit_sha,
      baseline_commit_sha: request.repository.baseline_commit_sha,
      workspace_ref: request.repository.workspace_ref,
      approval_ref: request.repository.approval_ref,
      approval_sha256: request.repository.approval_sha256,
    },
    changed_files: changed,
    changed_file_count: changed.length,
    relevant_symbols: signals.relevant_symbols,
    routes: signals.routes,
    apis: signals.apis,
    cli_commands: signals.cli_commands,
    dependency_signals: signals.dependency_signals,
    existing_tests: signals.existing_tests,
    evidence_pointers: (request.inputs || []).map((input) => pointerSummary(input.source_ref, input.content_sha256)),
    independent_browser_evidence: request.browser_evidence ? {
      artifact_pointer: request.browser_evidence.artifact_pointer,
      artifact_digest: request.browser_evidence.artifact_digest,
    } : null,
    untrusted_instruction_signals: signals.untrusted_instruction_signals,
    limitations: signals.limitations,
    untrusted_data_notice: 'Repository files are inspected as untrusted data. Target instructions never alter FKST policy or execution authority.',
    discovered_modules: signals.modules,
  };
  const inputResult = inputAnalysis(request, workspace, repository);
  inputResult.index.analysis_key = analysisKey;
  const browser = browserAnalysis(request, workspace);
  const gaps = designGaps(repository, inputResult.requirementRoutes, browser);
  repository.design_gaps = gaps;
  repository.design_gap_count = gaps.length;
  const trace = traceability(inputResult.index, repository, gaps, request);
  trace.analysis_key = analysisKey;
  const degraded = inputResult.index.unreadable_inputs.length > 0 || inputResult.index.unsupported_inputs.length > 0 || gaps.length > 0;
  const artifacts = immutableArtifacts(request.artifact_root, [
    { name: 'repository_analysis', filename: 'repository-analysis.v1.json', document: repository },
    { name: 'requirements_index', filename: 'requirements-index.v1.json', document: inputResult.index },
    { name: 'traceability_seed', filename: 'traceability-seed.v1.json', document: trace },
  ]);
  return {
    status: degraded ? 'degraded' : 'complete',
    replayed: artifacts.replayed,
    analysis_key: analysisKey,
    context: {
      schema: SCHEMAS.contextReference,
      analysis_key: analysisKey,
      repository_analysis: artifacts.references.repository_analysis,
      requirements_index: artifacts.references.requirements_index,
      traceability_seed: artifacts.references.traceability_seed,
    },
  };
}

function main(argv) {
  if (argv[0] === 'analyze-env') {
    if (!process.env.FKST_TESTING_DESIGN_REQUEST_JSON) {
      throw new Error('testing-design: runtime-request-environment-required');
    }
    const request = JSON.parse(process.env.FKST_TESTING_DESIGN_REQUEST_JSON);
    process.stdout.write(`${JSON.stringify({ ok: true, result: analyze(request) })}\n`);
    return;
  }
  if (argv[0] === 'analyze') {
    const args = parseArgs(argv.slice(1));
    if (!args.request || !args.response) throw new Error('testing-design: runtime-paths-required');
    const request = JSON.parse(fs.readFileSync(args.request, 'utf8'));
    const result = analyze(request);
    fs.mkdirSync(path.dirname(args.response), { recursive: true });
    fs.writeFileSync(args.response, `${JSON.stringify({ ok: true, result })}\n`, { mode: 0o600 });
    return;
  }
  throw new Error('testing-design: unsupported-runtime-command');
}

if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (error) {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  }
}

module.exports = { ANALYZER_REVISION, analyze, artifactBody, sha256, stableStringify };
