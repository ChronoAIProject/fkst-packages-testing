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
    heartbeat_url = payload.heartbeat_url,
    final_summary = payload.final_summary,
    no_browser = payload.no_browser,
    dry_run = payload.dry_run,
    dry_run_github = payload.dry_run_github,
    backend = payload.backend,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    source_ref = payload.source_ref,
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

local function expect_equal(errors, id, actual, expected)
  if actual == expected then return end
  add_error(errors, id, "online transition expected " .. tostring(expected) .. " but got " .. tostring(actual))
end

function M.saga_conformance_errors()
  local ok, request = pcall(M.runner_request, {
    schema = "online-regression.start.v1",
    driver = "conformance-driver",
    heartbeat_url = "conformance-heartbeat",
    backend = "fkst-native",
    no_browser = true,
    dry_run = false,
    preflight_result = { status = "ready" },
    artifact_root = ".testing/runs/conformance-online",
    source_ref = { kind = "host-online", ref = "conformance-online" },
    trace_id = "trace-conformance-online",
    dedup_key = "conformance-online-run",
  })
  local errors = {}
  if not ok then
    add_error(errors, "online-regression.saga.runner-request", tostring(request))
    return errors
  end
  expect_equal(errors, "online-regression.saga.schema", request.schema, "testing-runner.online-regression.request.v1")
  expect_equal(errors, "online-regression.saga.driver", request.driver, "conformance-driver")
  expect_equal(errors, "online-regression.saga.heartbeat-url", request.heartbeat_url, "conformance-heartbeat")
  expect_equal(errors, "online-regression.saga.backend", request.backend, "fkst-native")
  expect_equal(errors, "online-regression.saga.no-browser", request.no_browser, true)
  expect_equal(errors, "online-regression.saga.dry-run", request.dry_run, false)
  expect_equal(errors, "online-regression.saga.artifact-root", request.artifact_root, ".testing/runs/conformance-online")
  expect_equal(errors, "online-regression.saga.trace-id", request.trace_id, "trace-conformance-online")
  expect_equal(errors, "online-regression.saga.dedup-key", request.dedup_key, "conformance-online-run")
  return errors
end

return M
