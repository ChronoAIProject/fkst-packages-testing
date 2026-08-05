local adapter = require("host_workflow_qa_adapter")
local process = require("test_support.durable_workflow_qa_process")
local support = require("test_support.canonical_workflow_qa")
local t = fkst.test

local function count_checkpoints(ledger)
  local count = 0
  for _, _ in pairs((ledger or {}).checkpoints or {}) do count = count + 1 end
  return count
end

return {
  test_canonical_workflow_qa_executes_real_fixture_and_replays_terminal = function()
    local context = support.new()
    local ok, err = pcall(function()
      local lifecycle = context:run_lifecycle()

      t.eq(context.terminal.status, "passed")
      t.eq(context.terminal.counts.planned, 2)
      t.eq(context.terminal.counts.executed, 2)
      t.eq(context.terminal.counts.passed, 2)
      t.eq(context.terminal.counts.failed, 0)
      t.eq(context.terminal_records, 1)
      t.eq(context.preauthorization_claims, 1)
      t.eq(context.execution_claims, 1)

      t.eq(#context.target_effects, 2)
      t.eq(context.target_effects[1].kind, "cli")
      t.eq(context.target_effects[1].argv[1], "node")
      t.eq(context.target_effects[1].argv[2], "cli.js")
      t.eq(context.target_effects[2].kind, "http")
      t.eq(context.target_effects[2].url, context.target_url)
      for _, case_id in ipairs({ "cli-version", "health" }) do
        local authorization = context.store:load(
          context.request.structured_execution.artifact_root .. "/authorization/" .. case_id .. ".json")
        t.eq(authorization.value.schema, "testing-effect-authorization-receipt.v1")
        t.eq(authorization.value.decision, "allow")
        t.eq(authorization.value.reason_code, "authorized")
      end

      local ledger = context.publication_ledger
      t.eq(ledger.latest_stage_rank, 100)
      t.eq(count_checkpoints(ledger), 8)
      for _, checkpoint in pairs(ledger.checkpoints) do
        t.eq(checkpoint.receipt.schema, "test-publication.qa-publication-receipt.v2")
        t.eq(checkpoint.receipt.status, "published")
      end

      local aggregate = context.store:load(context.request.publication.aggregate_report_ref).value
      t.eq(aggregate.status, "passed")
      t.eq(aggregate.finalization_kind, "full")
      t.eq(aggregate.counts.passed, 2)
      t.eq(aggregate.residual_risks, 0)
      t.eq(aggregate.cleanup_receipt_ref, context.terminal.cleanup_receipt_ref)
      t.is_true(type(aggregate.artifact_links.browser_readiness) == "string")
      t.is_true(type(aggregate.artifact_links.case_results) == "string")

      local cleanup = context.store:load(context.terminal.cleanup_receipt_ref).value
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      t.is_true(#cleanup.verified_removals >= 3)
      local absent = os.execute("test ! -e " .. string.format("%q", context.workspace_root))
      t.is_true(absent == true or absent == 0)

      local target_effect_count = #context.target_effects
      local publication_count = context.publication_count
      local grant_write_count = context.store:write_count(context.request.structured_execution.grant_ref)
      local terminal_records = context.terminal_records

      local terminal_actions = lifecycle.workflow.start(context.request, context.workflow_runtime)
      t.eq(terminal_actions[1].queue, "workflow_qa_terminal_request")
      adapter.handle_terminal(terminal_actions[1].payload, context.generic_host_runtime)
      local final_replay = lifecycle.publication.prepare_final_report(
        context.workflow_state.finalization_request, context.publication_runtime)
      t.eq(final_replay.replayed, true)
      t.eq(final_replay.status, "published")

      t.eq(#context.target_effects, target_effect_count)
      t.eq(context.publication_count, publication_count)
      t.eq(context.store:write_count(context.request.structured_execution.grant_ref), grant_write_count)
      t.eq(context.preauthorization_claims, 1)
      t.eq(context.execution_claims, 1)
      t.eq(context.terminal_records, terminal_records)
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

  test_canonical_http_gateway_rejects_redirect_without_following = function()
    local context = support.new({
      http_only = true,
      count_effect = true,
      http_redirect_response = true,
    })
    local ok, err = pcall(function()
      local supervisor = require("test_support.host_workflow_qa_supervisor")
      local prepared = supervisor.prepare_phase(
        context, context.project_root, "structured-execution-pending")
      local outcome = prepared.structured.run(
        prepared.pending_action.payload, context.structured_runtime)
      t.eq(outcome.status, "blocked")
      t.eq(outcome.error_count, 1)
      t.eq(#context.target_effects, 0)
      t.eq(process.http_effect_count(context), 1)
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

  test_canonical_local_pep_denies_changed_plan_binding_without_http_effect = function()
    local context = support.new({
      http_only = true,
      count_effect = true,
      pep_mutate_plan_binding = true,
    })
    local ok, err = pcall(function()
      local supervisor = require("test_support.host_workflow_qa_supervisor")
      local prepared = supervisor.prepare_phase(
        context, context.project_root, "structured-execution-pending")
      local outcome = prepared.structured.run(
        prepared.pending_action.payload, context.structured_runtime)
      t.eq(outcome.status, "blocked")
      t.eq(outcome.error_count, 1)
      t.eq(#context.target_effects, 0)
      t.eq(process.effect_count(context), 0)
      t.eq(process.http_effect_count(context), 0)
      local receipt = context.store:load(
        context.request.structured_execution.artifact_root .. "/authorization/health.json")
      t.eq(receipt.value.schema, "testing-effect-authorization-receipt.v1")
      t.eq(receipt.value.decision, "deny")
      t.eq(receipt.value.reason_code, "foreign-binding")
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

}
