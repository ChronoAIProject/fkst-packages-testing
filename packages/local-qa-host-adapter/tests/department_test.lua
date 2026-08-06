local adapter = require("adapter")
local structured_execution = require("contract.structured_execution")
local dead_letter = require("departments.dead_letter.main")
local execution_grant = require("departments.execution_grant.main")
local seam = require("departments.seam.main")
local testing = require("testkit.testing")
local t = fkst.test

local function digest(char)
  return string.rep(char, 64)
end

local function grant_request()
  local root = ".testing/runs/local-qa-department-test"
  return {
    schema = structured_execution.schemas.grant_request,
    execution_mode = "structured-api-cli",
    repository = {
      url = "https://example.invalid/repository.git",
      commit_sha = string.rep("1", 40),
    },
    preauthorization_ref = root .. "/preauthorization.json",
    preauthorization_sha256 = digest("1"),
    plan_ref = root .. "/plan.json",
    plan_sha256 = digest("2"),
    environment_receipt_ref = root .. "/environment-receipt.json",
    environment_receipt_sha256 = digest("3"),
    grant_ref = root .. "/grant.json",
    trace_id = "trace-local-qa-department-test",
    dedup_key = "dedup-local-qa-department-test",
    source_ref = { kind = "workflow-qa", ref = "local-qa-department-test" },
  }
end

return {
  test_default_runtime_provider_is_exercised = function()
    local previous = _G.local_qa_workflow_qa_runtime
    _G.local_qa_workflow_qa_runtime = {}
    local ok = pcall(adapter.handle_execution_grant, grant_request())
    _G.local_qa_workflow_qa_runtime = previous
    t.eq(ok, false)
  end,

  test_execution_grant_department_raises_adapter_result = function()
    local original = adapter.handle_execution_grant
    adapter.handle_execution_grant = function()
      return {
        queue = "workflow-qa.execution_grant_result",
        payload = { schema = "fixture.execution-grant-result.v1" },
      }
    end
    local ok, trace = pcall(testing.run_fake, execution_grant, {
      queue = "workflow-qa.workflow_qa_execution_grant_request",
      payload = {},
    })
    adapter.handle_execution_grant = original
    if not ok then error(trace) end
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "workflow-qa.execution_grant_result")
  end,

  test_dead_letter_and_seam_departments_accept_events = function()
    local dead_trace = testing.run_fake(dead_letter, {
      queue = "dead_letter",
      payload = {
        delivery_id = "delivery-local-qa-department-test",
        queue = "qa_run_request",
        dept = "intake",
        error_class = "fixture-failure",
        error = "fixture failure",
        attempt = 1,
        source_ref = { kind = "external", ref = "local-qa-department-test" },
      },
    })
    t.eq(#dead_trace.raises, 0)

    local seam_trace = testing.run_fake(seam, {
      queue = "local_qa_host_tick",
      payload = {},
    })
    t.eq(#seam_trace.raises, 0)
  end,
}
