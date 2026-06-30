# testing-artifacts.v1

Testing packages exchange artifact pointers, not report bodies.

## Artifact summary

`test-artifacts.artifact_summary` uses `test-artifacts.summary.v1`:

- `job`: logical testing job name
- `status`: `planned`, `passed`, `failed`, `blocked`, or `mixed`
- `artifact_root`: stable local or handoff pointer, usually `.testing/runs/<run>`
- `source_ref`: optional bounded source reference

## Publication handoff

`test-publication.publication_request` uses `test-publication.publication-request.v1` and forwards only the status, job, artifact root, and source reference needed by a host publisher.
