'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { sha256, stableStringify } = require('../../../packages/testing-design/bin/testing-design-runtime');

const projectRoot = process.argv[2];
const tempRoot = process.argv[3];
const artifactRoot = process.argv[4];
const fixtureRoot = path.join(projectRoot, 'packages/testing-design/tests/fixtures/pql/v1');
const repositoryUrl = 'https://example.invalid/project.git';

function run(argv, cwd, env) {
  const result = spawnSync(argv[0], argv.slice(1), { cwd, env: { ...process.env, ...env }, encoding: 'utf8', shell: false });
  if (result.status !== 0) throw new Error(`${argv.join(' ')} failed: ${result.stderr}`);
  return result.stdout.trim();
}

function write(filePath, body) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, body);
  return sha256(Buffer.from(body));
}

function document(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(fixtureRoot, relativePath), 'utf8'));
}

function artifact(ref) {
  return { kind: 'artifact', ref };
}

fs.rmSync(tempRoot, { recursive: true, force: true });
fs.rmSync(path.join(projectRoot, artifactRoot), { recursive: true, force: true });
const workspace = path.join(tempRoot, 'workspace');
fs.mkdirSync(workspace, { recursive: true });
run(['git', 'init', '--quiet'], workspace);
run(['git', 'config', 'user.email', 'fixture@example.invalid'], workspace);
run(['git', 'config', 'user.name', 'PQL Walking Skeleton'], workspace);
write(path.join(workspace, 'src', 'app.js'), "module.exports = 'baseline';\n");
run(['git', 'add', '.'], workspace);
run(['git', 'commit', '--quiet', '-m', 'baseline'], workspace, {
  GIT_AUTHOR_DATE: '2026-08-27T00:00:00Z', GIT_COMMITTER_DATE: '2026-08-27T00:00:00Z',
});
const baseline = run(['git', 'rev-parse', 'HEAD'], workspace);
write(path.join(workspace, 'src', 'app.js'), "module.exports = 'home-title';\n");
run(['git', 'add', '.'], workspace);
run(['git', 'commit', '--quiet', '-m', 'home title'], workspace, {
  GIT_AUTHOR_DATE: '2026-08-27T00:01:00Z', GIT_COMMITTER_DATE: '2026-08-27T00:01:00Z',
});
const target = run(['git', 'rev-parse', 'HEAD'], workspace);
fs.appendFileSync(path.join(workspace, '.git', 'info', 'exclude'), '\n.testing/fixtures/pql/\n');

const assetBody = fs.readFileSync(path.join(fixtureRoot, 'assets/home-title-tests.txt'), 'utf8');
const assetRef = '.testing/fixtures/pql/assets/home-title-tests.txt';
const assetDigest = write(path.join(workspace, assetRef), assetBody);
const snapshotRef = '.testing/fixtures/pql/snapshots/home-title.json';
const snapshot = document('snapshots/home-title.json');
snapshot.repository_commit_sha = target;
snapshot.assets[0].artifact_pointer = artifact(assetRef);
snapshot.assets[0].artifact_digest = assetDigest;
const snapshotDigest = write(path.join(workspace, snapshotRef), `${stableStringify(snapshot)}\n`);
const reviewRef = '.testing/fixtures/pql/reviews/home-title.json';
const review = document('reviews/home-title.json');
review.subject.repository_commit_sha = target;
review.subject.project_pack_snapshot_ref = artifact(snapshotRef);
review.subject.project_pack_snapshot_sha256 = snapshotDigest;
review.subject.asset_sha256 = assetDigest;
const reviewDigest = write(path.join(workspace, reviewRef), `${stableStringify(review)}\n`);
const promotionRef = '.testing/fixtures/pql/promotion/home-title.json';
const promotion = document('promotion/home-title.json');
promotion.subject = JSON.parse(JSON.stringify(review.subject));
promotion.review_decision_ref = artifact(reviewRef);
promotion.review_decision_sha256 = reviewDigest;
const promotionDigest = write(path.join(workspace, promotionRef), `${stableStringify(promotion)}\n`);

const inputSet = document('input-set.json');
inputSet.repository.commit_sha = target;
inputSet.project_pack_snapshot = { ref: artifact(snapshotRef), sha256: snapshotDigest };
inputSet.approved_assets[0].artifact_pointer = artifact(assetRef);
inputSet.approved_assets[0].artifact_digest = assetDigest;
inputSet.approved_assets[0].review_decision = { ref: artifact(reviewRef), sha256: reviewDigest };
inputSet.approved_assets[0].promotion_receipt = { ref: artifact(promotionRef), sha256: promotionDigest };
inputSet.approved_assets[0].approval_subject = JSON.parse(JSON.stringify(review.subject));

const approvalPath = path.join(tempRoot, 'repository-approval.json');
const approval = {
  schema: 'testing-design.approval.v1',
  subject_kind: 'repository',
  repository_url: repositoryUrl,
  workspace_ref: { kind: 'workspace', ref: workspace },
  target_commit_sha: target,
  baseline_commit_sha: baseline,
};
const approvalDigest = write(approvalPath, `${stableStringify(approval)}\n`);
process.stdout.write(stableStringify({
  schema: 'testing-design.analysis-request.v1',
  repository: {
    url: repositoryUrl,
    commit_sha: target,
    baseline_commit_sha: baseline,
    workspace_ref: { kind: 'workspace', ref: workspace },
    approval_ref: { kind: 'file', ref: approvalPath },
    approval_sha256: approvalDigest,
  },
  inputs: [],
  pql_input_set: inputSet,
  artifact_root: artifactRoot,
  source_ref: { kind: 'workflow-qa', ref: 'pql-home-title' },
  trace_id: 'trace-pql-home-title',
  dedup_key: 'dedup-pql-home-title',
}));
