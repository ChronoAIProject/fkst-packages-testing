local execution = require("contract.testing_execution")
local receipt_validator = require("testing_runtime.receipt")
local t = fkst.test

local digest = string.rep("a", 64)

local function request()
  return {
    schema = execution.schemas.execution_request,
    module = "catalog",
    trace_id = "trace-catalog",
    dedup_key = "catalog-run",
    artifact_root = ".testing/runs/catalog",
    base_url = "http://localhost:4173/catalog",
    allowed_origins = { "http://localhost:4173" },
    cdp_url = "http://127.0.0.1:9222",
    step_budget = 1,
    plan_sha256 = digest,
    actions = {
      {
        step = 1,
        module_id = "catalog",
        case_id = "catalog:reachability",
        priority = "P0",
        action = "navigate",
        target = "http://localhost:4173/catalog/list",
        url = "http://localhost:4173/catalog/list",
        assertions = {
          { type = "url-within-scope" },
          { type = "document-ready" },
        },
      },
    },
  }
end

local function receipt()
  return {
    schema = execution.schemas.execution_receipt,
    module = "catalog",
    request_sha256 = digest,
    status = "passed",
    classification = "typed-browser-assertions-passed",
    action_count = 1,
    executed_action_count = 1,
    failed_action_count = 0,
    blocked_action_count = 0,
    actions = {
      {
        step = 1,
        case_id = "catalog:reachability",
        action = "navigate",
        execution_status = "executed",
        assertion_status = "passed",
        observation = "typed browser action completed",
        evidence_pointer = ".testing/runs/catalog/evidence/execution/catalog-reachability.json",
        assertion_results = {
          {
            type = "url-within-scope",
            status = "passed",
            observation = "same origin and scope",
            evidence_pointer = ".testing/runs/catalog/evidence/execution/catalog-reachability.json",
          },
          {
            type = "document-ready",
            status = "passed",
            observation = "document.readyState=complete",
            evidence_pointer = ".testing/runs/catalog/evidence/execution/catalog-reachability.json",
          },
        },
      },
    },
  }
end

return {
  test_accepts_typed_execution_request_and_bound_receipt = function()
    local req = request()
    local value = receipt()
    t.eq(execution.validate_execution_request(req).module, "catalog")
    t.eq(execution.validate_execution_receipt(value).status, "passed")
    t.eq(receipt_validator.validate(req, value).status, "passed")
  end,

  test_rejects_receipt_missing_requested_assertion = function()
    local req = request()
    local value = receipt()
    table.remove(value.actions[1].assertion_results, 2)
    t.raises(function() receipt_validator.validate(req, value) end)
  end,

  test_rejects_receipt_with_reordered_assertions = function()
    local req = request()
    local value = receipt()
    value.actions[1].assertion_results[1], value.actions[1].assertion_results[2] =
      value.actions[1].assertion_results[2], value.actions[1].assertion_results[1]
    t.raises(function() receipt_validator.validate(req, value) end)
  end,

  test_rejects_receipt_with_foreign_evidence_pointer = function()
    local req = request()
    local value = receipt()
    value.actions[1].evidence_pointer = ".testing/runs/foreign/evidence/action.json"
    t.raises(function() receipt_validator.validate(req, value) end)
  end,

  test_rejects_receipt_with_foreign_assertion_evidence_pointer = function()
    local req = request()
    local value = receipt()
    value.actions[1].assertion_results[2].evidence_pointer = ".testing/runs/foreign/evidence/assertion.json"
    t.raises(function() receipt_validator.validate(req, value) end)
  end,

  test_rejects_inconsistent_passed_action_assertion_status = function()
    local value = receipt()
    value.actions[1].assertion_status = "failed"
    t.raises(function() execution.validate_execution_receipt(value) end)
  end,

  test_accepts_failed_receipt_with_failed_assertion = function()
    local req = request()
    local value = receipt()
    value.status = "failed"
    value.classification = "typed-browser-assertion-failed"
    value.executed_action_count = 0
    value.failed_action_count = 1
    value.actions[1].execution_status = "failed"
    value.actions[1].assertion_status = "failed"
    value.actions[1].assertion_results[2].status = "failed"
    t.eq(receipt_validator.validate(req, value).status, "failed")
  end,

  test_rejects_failed_receipt_with_pass_classification = function()
    local value = receipt()
    value.status = "failed"
    value.executed_action_count = 0
    value.failed_action_count = 1
    value.actions[1].execution_status = "failed"
    value.actions[1].assertion_status = "failed"
    value.actions[1].assertion_results[2].status = "failed"
    t.raises(function() execution.validate_execution_receipt(value) end)
  end,

  test_rejects_false_pass_without_executed_actions = function()
    local value = receipt()
    value.actions[1].execution_status = "blocked"
    value.actions[1].assertion_status = "blocked"
    value.executed_action_count = 0
    value.blocked_action_count = 1
    t.raises(function() execution.validate_execution_receipt(value) end)
  end,

  test_rejects_destructive_fixture_lifecycle = function()
    t.raises(function()
      execution.validate_fixture_lifecycle({
        schema = execution.schemas.fixture_lifecycle,
        case_id = "catalog:write-flow",
        mutation_kind = "delete",
        prepare_argv = { "fixture", "prepare" },
        verify_ready_argv = { "fixture", "verify" },
        cleanup_argv = { "fixture", "cleanup" },
        verify_clean_argv = { "fixture", "verify-clean" },
      })
    end)
  end,
}
