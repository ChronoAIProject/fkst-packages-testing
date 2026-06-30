# testing-runner.v1

`testing-runner` is the initial adapter boundary between fkst events and the existing `agentic-testing` Python CLI.

## Request queues

- `testing-runner.module_test_request`
  - `schema`: `testing-runner.module-test-loop.request.v1`
  - required: `module`
  - optional: `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`
- `testing-runner.platform_test_request`
  - `schema`: `testing-runner.platform-test-loop.request.v1`
  - optional: `modules`, `priority`, `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`
- `testing-runner.online_regression_request`
  - `schema`: `testing-runner.online-regression.request.v1`
  - optional: `config`, `driver`, `final_summary`, `no_browser`, `dry_run`, `dry_run_github`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`

## Result queue

All request types emit `testing-runner.testing_result` with:

- `schema`: `testing-runner.result.v1`
- `job`: `module-test-loop`, `platform-test-loop`, or `online-regression`
- `status`: `planned`, `passed`, `failed`, or `blocked`
- `artifact_root`: stable pointer under `.testing/runs/...`
- `source_ref`: bounded source reference
- `adapter`: `{ name = "agentic-testing-cli", command = "..." }`

Payloads must carry small control fields and artifact pointers only; large report bodies, browser storage, credentials, cookies, and tokens stay outside fkst events.
