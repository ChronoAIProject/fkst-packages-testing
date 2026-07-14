local core = require("core")
local native = require("fkst_native")

local M = {}

M.spec = {
  consumes = { "screenshot_evidence_smoke" },
  produces = {},
  stall_window = "2m",
  retry = false,
}

local function expect_equal(actual, expected, field)
  if actual ~= expected then
    error("screenshot-evidence-smoke: " .. field .. " expected " .. tostring(expected) .. " but received " .. tostring(actual))
  end
end

local function expect_true(value, field)
  if value ~= true then error("screenshot-evidence-smoke: " .. field .. " must be true") end
end

local function pointer_equal(actual, expected, field)
  expect_equal(actual.path, expected.path, field .. ".path")
  expect_equal(actual.media_type, expected.media_type, field .. ".media_type")
  expect_equal(actual.size_bytes, expected.size_bytes, field .. ".size_bytes")
  expect_equal(actual.sha256, expected.sha256, field .. ".sha256")
end

local function write_text(path, body)
  local handle, err = io.open(path, "w")
  if handle == nil then error(err or "screenshot-evidence-smoke: failed to open output") end
  handle:write(body)
  handle:close()
end

function M.pipeline(_event)
  local base_url = assert(os.getenv("FKST_SCREENSHOT_BASE_URL"))
  local cdp_url = assert(os.getenv("FKST_SCREENSHOT_CDP_URL"))
  local artifact_root = assert(os.getenv("FKST_SCREENSHOT_ARTIFACT_ROOT"))
  local origin = assert(base_url:match("^(http://[^/]+)"))
  local result = core.run("module", {
    schema = "testing-runner.module-test-loop.request.v1",
    backend = "fkst-native",
    module = "screenshot-evidence-smoke",
    dry_run = false,
    ui_loop = {
      base_url = base_url,
      allowed_origins = { origin },
      cdp_readiness_ref = "screenshot-evidence-cdp-ready",
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "account-summary",
          name = "Missing account summary",
          entry_url = base_url .. "/dashboard/",
          visible_label = "Missing account summary",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = ".testing/runs/screenshot-evidence-fixture/observation.json",
        },
      },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 4,
      case_priorities = { "P0" },
      redaction_selectors = { "[data-fkst-sensitive]" },
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "browser", status = "ready", cdp_url = cdp_url },
      },
    },
    artifact_root = artifact_root,
    trace_id = "trace-screenshot-evidence-smoke",
    dedup_key = "screenshot-evidence-smoke",
  })

  if result.status ~= "failed" then
    error("screenshot-evidence-smoke: expected failed runner result, received " .. native.json_encode(result))
  end
  expect_equal(result.native_summary.classification, "typed-browser-assertion-failed", "classification")
  expect_equal(result.native_summary.failed_action_count, 1, "failed_action_count")
  local event_pointer = result.native_summary.failure_screenshot
  expect_equal(event_pointer.path, artifact_root .. "/evidence/screenshots/failure.png", "event screenshot path")
  expect_equal(event_pointer.media_type, "image/png", "event screenshot media type")
  expect_true(event_pointer.size_bytes > 8, "event screenshot size")
  expect_equal(#event_pointer.sha256, 64, "event screenshot digest length")

  local receipt = json.decode(file.read(artifact_root .. "/browser-execution-receipt.json"))
  local failed_assertion
  for _, action in ipairs(receipt.actions) do
    for _, assertion in ipairs(action.assertion_results) do
      if assertion.status == "failed" then
        expect_equal(failed_assertion, nil, "single failed assertion")
        failed_assertion = assertion
      end
    end
  end
  expect_true(failed_assertion ~= nil, "failed assertion present")
  pointer_equal(failed_assertion.screenshot_artifact, event_pointer, "receipt screenshot")

  local index = json.decode(file.read(artifact_root .. "/evidence/screenshot-index.json"))
  expect_equal(index.ref_count, 1, "screenshot index count")
  pointer_equal(index.refs[1], event_pointer, "screenshot index entry")

  local failures = json.decode(file.read(artifact_root .. "/evidence/failures.json"))
  expect_equal(failures.failed_assertion_count, 1, "failed assertion count")
  pointer_equal(failures.failed_assertions[1].screenshot_artifact, event_pointer, "failure attribution screenshot")

  local report = file.read(artifact_root .. "/stage-report.md")
  expect_true(report:find(event_pointer.path, 1, true) ~= nil, "report screenshot path")
  expect_true(report:find(event_pointer.sha256, 1, true) ~= nil, "report screenshot digest")
  expect_equal(report:find("fixture-secret-71", 1, true), nil, "report fixture secret")

  local event_body = native.json_encode(result) .. "\n"
  expect_true(event_body:find(event_pointer.path, 1, true) ~= nil, "event screenshot pointer")
  expect_equal(event_body:find("fixture-secret-71", 1, true), nil, "event fixture secret")
  expect_equal(event_body:find("data:image", 1, true), nil, "event inline image")
  write_text(artifact_root .. "/event.json", event_body)
  log.info("screenshot-evidence-smoke tag=PASSED artifact=" .. event_pointer.path)
end

_G.pipeline = M.pipeline
return M
