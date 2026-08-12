local browser_contract = require("contract.browser_control")
local contract = require("contract.workflow_qa")
local core = require("core")
local design_loop = require("testing_ai.module_ai_design_loop")
local execution_contract = require("contract.structured_execution")
local t = fkst.test

local helpers = require("tests.workflow_core_test_helpers").build({
  browser_contract = browser_contract,
  contract = contract,
  design_loop = design_loop,
  execution_contract = execution_contract,
  t = t,
})

local function release_checkpoint(request, ports, state)
  local receipt = helpers.checkpoint_receipt(request, state().active_checkpoint)
  t.eq(ports.write_artifact(receipt.receipt_ref, receipt), true)
  return receipt, core.handle_publication_receipt(receipt, request, ports)
end

local forbidden_queues = {
  ["environment-factory.environment_finalize"] = true,
  ["environment-factory.environment_interrupt"] = true,
  ["test-publication.qa_finalize_request"] = true,
  ["workflow_qa_terminal_request"] = true,
}

local function assert_redrive(state, phase, version, queue, actions)
  t.eq(state().phase, phase)
  t.eq(state().version, version)
  t.eq(#actions, 1)
  t.eq(actions[1].queue, queue)
  t.eq(forbidden_queues[actions[1].queue], nil)
end

return {
  test_out_of_order_events_cannot_authorize_structured_terminalization = function()
    local request = helpers.fixture()
    local ports, state, put = helpers.runtime(request)

    core.start(request, ports)
    release_checkpoint(request, ports, state)
    core.handle_environment_result(helpers.ready_result(request, put), request, ports)
    release_checkpoint(request, ports, state)
    core.handle_analysis_result(helpers.analysis_result(request), request, ports)
    release_checkpoint(request, ports, state)
    core.handle_browser_readiness_result(helpers.workflow_readiness_result(request), request, ports)
    release_checkpoint(request, ports, state)
    core.handle_module_terminal(helpers.module_terminal(request, put), request, ports)
    local stale_receipt, plan_actions = release_checkpoint(request, ports, state)
    t.eq(plan_actions[1].queue, "testing-runner.structured_plan_request")

    local early_execution = helpers.execution_result(request, 0)
    local duplicate_environment = helpers.copy(state().environment_result)
    local version = state().version
    assert_redrive(state, "structured-plan-pending", version, "testing-runner.structured_plan_request",
      core.handle_execution_result(early_execution, request, ports))
    assert_redrive(state, "structured-plan-pending", version, "testing-runner.structured_plan_request",
      core.handle_environment_result(duplicate_environment, request, ports))
    assert_redrive(state, "structured-plan-pending", version, "testing-runner.structured_plan_request",
      core.handle_publication_receipt(stale_receipt, request, ports))

    local grant_actions = core.handle_plan_result(helpers.plan_result(request, put), request, ports)
    t.eq(grant_actions[1].queue, "workflow_qa_execution_grant_request")
    version = state().version
    assert_redrive(state, "execution-grant-pending", version, "workflow_qa_execution_grant_request",
      core.handle_execution_result(early_execution, request, ports))
    assert_redrive(state, "execution-grant-pending", version, "workflow_qa_execution_grant_request",
      core.handle_environment_result(duplicate_environment, request, ports))
    assert_redrive(state, "execution-grant-pending", version, "workflow_qa_execution_grant_request",
      core.handle_publication_receipt(stale_receipt, request, ports))

    local execution_actions = core.handle_grant_result(helpers.grant_result(request, put), request, ports)
    t.eq(execution_actions[1].queue, "testing-runner.structured_execution_request")
    version = state().version
    assert_redrive(state, "structured-execution-pending", version,
      "testing-runner.structured_execution_request",
      core.handle_environment_result(duplicate_environment, request, ports))
    assert_redrive(state, "structured-execution-pending", version,
      "testing-runner.structured_execution_request",
      core.handle_publication_receipt(stale_receipt, request, ports))
  end,
}
