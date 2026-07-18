local core = require("core")
local contract = require("contract.environment_factory")

local M = {}

function M.saga_conformance_errors()
  local state_ref = {
    kind = "artifact",
    ref = ".testing/runs/environment-conformance/operation-state.json",
  }
  local ready_ref = {
    kind = "artifact",
    ref = ".testing/runs/environment-conformance/environment-receipt-ready.json",
  }
  local correlation = {
    schema = contract.schemas.readiness_correlation,
    attempt_id = "environment-conformance-attempt",
    operation_id = "environment-conformance",
    operation_state_ref = state_ref,
    environment_receipt_ref = ready_ref,
    base_url = "http://127.0.0.1:4312/ready",
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    trace_id = "trace-environment-conformance",
    dedup_key = "dedup-environment-conformance",
  }
  local ready = {
    schema = contract.schemas.result,
    operation_id = "environment-conformance",
    status = "ready",
    base_url = correlation.base_url,
    sessions = correlation.sessions,
    readiness_correlation = correlation,
    environment_receipt_ref = ready_ref,
    cleanup_ref = { kind = "environment-cleanup", ref = "environment-conformance" },
    diagnostic_refs = {},
    cleanup_status = "pending",
    trace_id = correlation.trace_id,
    dedup_key = correlation.dedup_key,
  }
  local check = core.browser_readiness_check(ready, { operation_state_ref = state_ref })
  assert(check.schema == "browser-readiness.check.v1", "environment-factory readiness conformance")
  return {}
end

return M
