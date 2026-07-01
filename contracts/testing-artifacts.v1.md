# testing-artifacts.v1

Testing packages exchange artifact pointers, not report bodies.

## Artifact summary

`test-artifacts.artifact_summary` uses `test-artifacts.summary.v1`:

- `job`: logical testing job name
- `status`: `planned`, `passed`, `failed`, `blocked`, or `mixed`
- `artifact_root`: stable local or handoff pointer, usually `.testing/runs/<run>`
- `metadata_path`: optional pointer to runner metadata, normally `<artifact_root>/metadata.json`
- `source_ref`: optional bounded source reference
- `adapter`: optional bounded adapter metadata from the runner result
- `native_summary`: optional bounded native summary from the runner result
- `exit_code`: optional numeric process exit code
- `stderr_excerpt`: optional bounded error excerpt

Artifact summaries must carry small control metadata and pointers only. They must not embed report bodies, raw stdout/stderr bodies, screenshots, traces, browser storage, credentials, cookies, or tokens.

## Publication handoff

`test-publication.publication_request` uses `test-publication.publication-request.v1` and forwards only stable notification fields and artifact pointers needed by a host publisher:

- `publication_kind`: `testing-summary`
- `channel`: `testing`
- `severity`: `success`, `failure`, `warning`, or `info`, derived from summary `status`
- `subject`: bounded one-line human-readable subject
- `dedup_key`: bounded stable key for host-side notification de-duplication
- `status`: summary status
- `job`: logical testing job name
- `artifact_root`: stable `.testing/runs/...` pointer
- `metadata_path`: optional metadata pointer, normally `<artifact_root>/metadata.json`
- `source_ref`: bounded source reference

Publication requests are handoff payloads only. They must not embed report bodies, raw stdout/stderr bodies, screenshots, traces, browser storage, credentials, cookies, or tokens.
