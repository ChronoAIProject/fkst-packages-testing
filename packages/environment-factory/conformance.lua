local core = require("core")
local contract = require("contract.environment_factory")

local M = {}

function M.saga_conformance_errors()
  local state_ref = {
    kind = "artifact",
    ref = ".testing/runs/environment-conformance/operation-state.json",
  }
  local state = {
    status = "readiness-pending",
    operation_state_ref = state_ref,
    base_url = "http://127.0.0.1:4312/ready",
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    readiness_correlation = {
      schema = contract.schemas.readiness_correlation,
      attempt_id = "environment-conformance-attempt",
      operation_id = "environment-conformance",
      operation_state_ref = state_ref,
      readiness_attempt_ref = {
        kind = "artifact",
        ref = ".testing/runs/environment-conformance/readiness-attempts/environment-conformance-attempt.json",
      },
      readiness_attempt_sha256 = string.rep("a", 64),
      base_url = "http://127.0.0.1:4312/ready",
      sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
      trace_id = "trace-environment-conformance",
      dedup_key = "dedup-environment-conformance",
    },
  }
  local check = core.browser_readiness_check(state)
  assert(check.schema == "browser-readiness.check.v1", "environment-factory readiness conformance")
  contract.validate_result({
    schema = contract.schemas.result,
    operation_id = "environment-conformance",
    status = "ready",
    environment_receipt_ref = {
      kind = "artifact",
      ref = ".testing/runs/environment-conformance/environment-receipt-ready.json",
    },
    cleanup_ref = { kind = "environment-cleanup", ref = "environment-conformance" },
    diagnostic_refs = {},
    cleanup_status = "pending",
    source_ref = state_ref,
    trace_id = "trace-environment-conformance",
    dedup_key = "dedup-environment-conformance",
  })
  return {}
end

return M
