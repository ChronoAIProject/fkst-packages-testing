# testing-design.v1

`testing-design` analyzes one approved immutable repository worktree plus bounded approved input pointers. Repository and document content is untrusted data. The package performs static inspection only; it never executes target commands, scripts, package hooks, or instructions found in target content.

## Request

Queue: `testing-design.analysis_request`

Schema: `testing-design.analysis-request.v1`

The request contains an immutable repository URL, target and baseline full commit IDs, an approved worktree pointer, repository approval pointer plus SHA-256, zero to sixteen approved input pointers, optional independent browser evidence, a `.testing/runs/...` artifact root, and bounded source/trace/dedup identity.

Input kinds are `requirements`, `design`, `api-schema`, and `existing-tests`. Every input carries a source pointer, immutable revision, content SHA-256, approval pointer, and approval SHA-256. Inline documents, target commands, credentials, cookies, tokens, raw environments, query-bearing pointers, and unknown fields are rejected by the contract.

Each approval pointer resolves to canonical JSON with schema `testing-design.approval.v1`. Repository approvals bind the repository URL, workspace pointer, target commit, and baseline commit. Input approvals bind the input kind, source pointer, revision, and content digest. Browser-evidence approvals bind the artifact pointer and digest. A readable approval file whose subject differs from the request fails closed; digest verification alone is not treated as authorization.

## Artifacts

The runtime creates these immutable canonical JSON artifacts under the request artifact root:

- `repository-analysis.v1.json` (`testing-design.repository-analysis.v1`): changed files, bounded symbols, routes, API and CLI surfaces, dependency signals, existing tests, evidence pointers, limitations, and untrusted-instruction signals.
- `requirements-index.v1.json` (`testing-design.requirements-index.v1`): stable requirement IDs, bounded summaries, acceptance-criteria summaries, source pointers/digests, and explicit unreadable or unsupported inputs.
- `traceability-seed.v1.json` (`testing-design.traceability-seed.v1`): evidence-backed requirement/repository/module mappings, candidate objectives, and explicit code/requirements/browser disagreements.

Existing artifact paths are never overwritten. A repeated request with the same immutable inputs must match the existing bytes and returns `replayed = true`; any differing existing artifact fails as an immutable artifact conflict.

## Result

Queue: `testing-design.analysis_result`

Schema: `testing-design.analysis-result.v1`

The result is pointer-only: status, replay flag, SHA-256 analysis key, three artifact pointer/digest references, source reference, trace ID, and dedup key. No repository content, requirement body, browser body, model prompt, or provider response is emitted in FKST events.

The result status is `degraded` when bounded inputs are unreadable/unsupported or when evidence sources disagree; the artifacts remain authoritative records of those gaps.
