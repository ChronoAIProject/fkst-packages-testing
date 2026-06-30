local M = {}

function M.validate_request(payload)
  if type(payload) ~= "table" then
    error("online-regression: malformed-request: payload must be a table")
  end
  if payload.schema ~= "online-regression.start.v1" then
    error("online-regression: unknown-schema: expected online-regression.start.v1")
  end
  return payload
end

function M.runner_request(payload)
  payload = M.validate_request(payload)
  return {
    schema = "testing-runner.online-regression.request.v1",
    config = payload.config,
    driver = payload.driver,
    final_summary = payload.final_summary,
    no_browser = payload.no_browser,
    dry_run = payload.dry_run,
    dry_run_github = payload.dry_run_github,
    artifact_root = payload.artifact_root,
    agentic_testing_repo_root = payload.agentic_testing_repo_root,
    source_ref = payload.source_ref,
  }
end

return M
