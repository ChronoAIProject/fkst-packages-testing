local execution = require("testing_runtime.execution")
local execution_contract = require("contract.testing_execution")
local strings = require("contract.strings")

local M = {}

M.spec = {
  consumes = { "live_cdp_smoke" },
  produces = {},
  stall_window = "5m",
  retry = false,
}

local function local_http_origin(value)
  if type(value) ~= "string" or value == "" or #value > 512 then return nil end
  if value:find("[%z\1-\31]") ~= nil or value:find("@", 1, true) ~= nil then return nil end
  local authority = value:match("^http://([^/?#]+)")
  if authority == nil then return nil end
  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%](.*)$")
  else
    host, port = authority:match("^([^:]+)(.*)$")
  end
  if host == nil or (port ~= "" and port:match("^:%d+$") == nil) then return nil end
  if port ~= "" then
    local number = tonumber(port:sub(2))
    if number == nil or number < 1 or number > 65535 then return nil end
  end
  host = host:lower()
  if host ~= "localhost" and host ~= "127.0.0.1" and host ~= "::1" then return nil end
  local normalized = host == "::1" and "[::1]" or host
  return "http://" .. normalized .. port
end

local function live_inputs()
  local base_url = os.getenv("FKST_LIVE_BASE_URL")
  local cdp_input = os.getenv("FKST_LIVE_CDP_URL")
  local artifact_root = os.getenv("FKST_LIVE_ARTIFACT_ROOT")
  local origin = local_http_origin(base_url)
  local cdp_origin = local_http_origin(cdp_input)
  if origin == nil then error("live-cdp-smoke: FKST_LIVE_BASE_URL must be a loopback HTTP URL") end
  if cdp_origin == nil or (cdp_input ~= cdp_origin and cdp_input ~= cdp_origin .. "/") then
    error("live-cdp-smoke: FKST_LIVE_CDP_URL must be a loopback HTTP origin")
  end
  if not strings.is_artifact_root(artifact_root) then
    error("live-cdp-smoke: FKST_LIVE_ARTIFACT_ROOT must be a safe .testing/runs/... path")
  end
  return base_url, origin, cdp_origin, artifact_root
end

local function expect_equal(actual, expected, field)
  if actual ~= expected then
    error(
      "live-cdp-smoke: " .. field .. " expected " .. tostring(expected) .. " but received " .. tostring(actual)
    )
  end
end

function M.pipeline(_event)
  local base_url, origin, cdp_url, artifact_root = live_inputs()
  local request = {
    schema = execution_contract.schemas.execution_request,
    module = "live-cdp-smoke",
    trace_id = "trace-live-cdp-smoke",
    dedup_key = "live-cdp-smoke",
    artifact_root = artifact_root,
    base_url = base_url,
    allowed_origins = { origin },
    cdp_url = cdp_url,
    step_budget = 2,
    actions = {
      {
        step = 1,
        module_id = "live-target",
        case_id = "live-target:navigate",
        priority = "P0",
        action = "navigate",
        target = base_url,
        url = base_url,
        assertions = {
          { type = "url-within-scope" },
          { type = "document-ready" },
        },
      },
      {
        step = 2,
        module_id = "live-target",
        case_id = "live-target:wait-for-load",
        priority = "P0",
        action = "wait-for-load",
        target = base_url,
        url = base_url,
        assertions = {
          { type = "document-ready" },
          { type = "url-within-scope" },
        },
      },
    },
  }

  local prepared, paths = execution.prepare(request)
  if type(prepared.plan_sha256) ~= "string" or #prepared.plan_sha256 ~= 64 then
    error("live-cdp-smoke: prepared request must contain a SHA-256 digest")
  end
  local receipt, execution_paths = execution.execute(prepared)
  expect_equal(receipt.status, "passed", "receipt.status")
  expect_equal(receipt.classification, "typed-browser-assertions-passed", "receipt.classification")
  expect_equal(receipt.action_count, 2, "receipt.action_count")
  expect_equal(receipt.executed_action_count, 2, "receipt.executed_action_count")
  expect_equal(receipt.failed_action_count, 0, "receipt.failed_action_count")
  expect_equal(receipt.blocked_action_count, 0, "receipt.blocked_action_count")
  expect_equal(execution_paths.receipt, paths.receipt, "receipt path")

  for index, action in ipairs(receipt.actions) do
    expect_equal(action.execution_status, "executed", "action.execution_status")
    expect_equal(action.assertion_status, "passed", "action.assertion_status")
    expect_equal(action.evidence_pointer:sub(1, #artifact_root + 1), artifact_root .. "/", "evidence root")
    local evidence = json.decode(file.read(action.evidence_pointer))
    expect_equal(evidence.schema, "testing-runtime.action-evidence.v1", "evidence.schema")
    expect_equal(evidence.case_id, request.actions[index].case_id, "evidence.case_id")
  end

  local persisted = json.decode(file.read(paths.receipt))
  expect_equal(persisted.request_sha256, prepared.plan_sha256, "persisted request digest")
  expect_equal(persisted.status, "passed", "persisted receipt status")
  log.info("live-cdp-smoke tag=PASSED actions=2 artifact_root=" .. artifact_root)
end

_G.pipeline = M.pipeline
return M
