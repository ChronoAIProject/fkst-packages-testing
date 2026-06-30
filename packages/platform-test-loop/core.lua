local M = {}

local function dense_list(value)
  if type(value) ~= "table" then
    return false
  end
  local n = #value
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > n then
      return false
    end
  end
  return true
end

function M.validate_request(payload)
  if type(payload) ~= "table" then
    error("platform-test-loop: malformed-request: payload must be a table")
  end
  if payload.schema ~= "platform-test-loop.start.v1" then
    error("platform-test-loop: unknown-schema: expected platform-test-loop.start.v1")
  end
  if payload.modules ~= nil and not dense_list(payload.modules) then
    error("platform-test-loop: malformed-request: modules must be a dense list")
  end
  if payload.priority ~= nil and not dense_list(payload.priority) then
    error("platform-test-loop: malformed-request: priority must be a dense list")
  end
  return payload
end

function M.runner_request(payload)
  payload = M.validate_request(payload)
  return {
    schema = "testing-runner.platform-test-loop.request.v1",
    modules = payload.modules,
    priority = payload.priority,
    config = payload.config,
    e2e_driver = payload.e2e_driver,
    no_browser = payload.no_browser,
    dry_run = payload.dry_run,
    dry_run_github = payload.dry_run_github,
    artifact_root = payload.artifact_root,
    agentic_testing_repo_root = payload.agentic_testing_repo_root,
    source_ref = payload.source_ref,
  }
end

return M
