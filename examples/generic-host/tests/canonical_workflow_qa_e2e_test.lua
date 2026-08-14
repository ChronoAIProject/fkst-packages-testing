local adapter = require("host_workflow_qa_adapter")
local process = require("test_support.durable_workflow_qa_process")
local support = require("test_support.canonical_workflow_qa")
local t = fkst.test

local function count_checkpoints(ledger)
  local count = 0
  for _, _ in pairs((ledger or {}).checkpoints or {}) do count = count + 1 end
  return count
end

local function find_case(cases, case_id)
  for _, case in ipairs(cases or {}) do
    if case.case_id == case_id or case.proposed_case_id == case_id then return case end
  end
  return nil
end

local function external_cases()
  return {
    {
      id = "external-cli-version", module_id = "service", priority = "P0",
      title = "External CLI version", objective = "Verify the CLI version through external intake.",
      case_kind = "cli", actions = { { action = "cli", target = "node cli.js --version", expected = "exit 0" } },
      expected_observable = "The CLI prints its version.",
      coverage_subject_ids = { "REQ-EXTERNAL-CLI" }, review_status = "executable",
    },
    {
      id = "external-http-health", module_id = "service", priority = "P0",
      title = "External HTTP health", objective = "Verify health through external intake.",
      case_kind = "api", actions = { { action = "http", target = "/health", expected = "HTTP 200" } },
      expected_observable = "The service reports healthy.",
      coverage_subject_ids = { "REQ-EXTERNAL-HTTP" }, review_status = "executable",
    },
  }
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
      t.eq(context.target_effects[2].url, context.base_url)

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

  test_canonical_local_pep_denies_changed_plan_binding_without_cli_effect = function()
    local context = support.new({
      cli_only = true,
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
      local receipt = context.store:load(
        context.request.structured_execution.artifact_root .. "/authorization/cli-version.json")
      t.eq(receipt.value.schema, "testing-effect-authorization-receipt.v1")
      t.eq(receipt.value.decision, "deny")
      t.eq(receipt.value.reason_code, "foreign-binding")
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

  test_external_cli_and_http_cases_reconcile_through_terminal_artifacts_and_replay = function()
    local context = support.new({
      publication_channel = "filesystem-dry-run-v1",
      external_proposed_cases = external_cases(),
      external_case_mappings = function(runtime)
        return {
          {
            proposed_case_id = "external-cli-version", case_id = "external-cli-version", kind = "cli",
            argv = runtime.cli_argv, timeout_seconds = 10,
            assertions = { { type = "exit-code", expected = 0 } },
          },
          {
            proposed_case_id = "external-http-health", case_id = "external-http-health", kind = "http",
            request = { method = "GET", url = runtime.base_url, headers = {} },
            timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } },
          },
        }
      end,
    })
    local ok, err = pcall(function()
      local lifecycle = context:run_lifecycle()
      t.eq(context.terminal.status, "passed")
      t.eq(context.terminal.counts.planned, 4)
      t.eq(context.terminal.counts.executed, 4)
      t.eq(context.terminal.counts.passed, 4)

      local mapping_ref = context.request.structured_execution.external_case_mapping_ref
      local mapping_sha256 = context.request.structured_execution.external_case_mapping_sha256
      local mapping = context.store:load(
        mapping_ref).value
      local catalog = context.store:load(context.request.structured_execution.case_catalog_ref).value
      local plan = context.store:load(context.request.structured_execution.structured_plan_ref).value
      local results_ref = context.request.structured_execution.artifact_root .. "/case-results.json"
      local results = context.store:load(results_ref).value
      local aggregate = context.store:load(context.request.publication.aggregate_report_ref).value

      t.eq(mapping.schema, "testing-external-case-mapping.v1")
      t.eq(#mapping.entries, 2)
      t.eq(find_case(mapping.entries, "external-cli-version").status, "mapped")
      t.eq(find_case(mapping.entries, "external-http-health").status, "mapped")
      t.is_true(find_case(catalog.cases, "external-cli-version") ~= nil)
      t.is_true(find_case(catalog.cases, "external-http-health") ~= nil)
      t.eq(catalog.external_case_mapping_sha256, mapping_sha256)
      t.is_true(find_case(plan.cases, "external-cli-version") ~= nil)
      t.is_true(find_case(plan.cases, "external-http-health") ~= nil)
      t.eq(plan.external_case_mapping_sha256, mapping_sha256)
      t.eq(find_case(results.cases, "external-cli-version").status, "passed")
      t.eq(find_case(results.cases, "external-http-health").status, "passed")
      t.eq(results.external_case_mapping_sha256, mapping_sha256)
      local cli_trace = find_case(aggregate.external_case_traceability, "external-cli-version")
      local http_trace = find_case(aggregate.external_case_traceability, "external-http-health")
      t.eq(cli_trace.final_status, "passed")
      t.eq(http_trace.final_status, "passed")
      t.eq(cli_trace.case_results_ref, results_ref)
      t.is_true(type(cli_trace.proposed_case_sha256) == "string")
      t.is_true(type(cli_trace.catalog_case_sha256) == "string")
      t.eq(aggregate.external_case_mapping_sha256, mapping_sha256)
      t.eq(aggregate.artifact_links.external_case_mapping, mapping_ref)

      local mapping_writes = context.store:write_count(mapping_ref)
      local mapping_digest = context.store:digest(mapping_ref)
      local terminal_actions = lifecycle.workflow.start(context.request, context.workflow_runtime)
      t.eq(terminal_actions[1].queue, "workflow_qa_terminal_request")
      adapter.handle_terminal(terminal_actions[1].payload, context.generic_host_runtime)
      local replay = lifecycle.publication.prepare_final_report(
        context.workflow_state.finalization_request, context.publication_runtime)
      t.eq(replay.replayed, true)
      t.eq(context.store:write_count(mapping_ref), mapping_writes)
      t.eq(context.store:digest(mapping_ref), mapping_digest)
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

  test_unsupported_external_case_fails_closed_with_rejection_traceability = function()
    local proposed = external_cases()[1]
    local context = support.new({ external_proposed_cases = { proposed } })
    local ok, err = pcall(function()
      context:run_lifecycle()
      t.eq(context.terminal.status, "blocked")
      t.eq(#context.target_effects, 0)
      t.eq(context.preauthorization_claims, 0)
      t.eq(context.execution_claims, 0)
      local mapping = context.store:load(
        context.request.structured_execution.external_case_mapping_ref).value
      local entry = find_case(mapping.entries, proposed.id)
      t.eq(entry.status, "rejected")
      t.eq(entry.rejection_reason, "host-has-no-authorized-execution-mapping")
      local aggregate = context.store:load(context.request.publication.aggregate_report_ref).value
      t.eq(aggregate.status, "blocked")
      local trace = find_case(aggregate.external_case_traceability, proposed.id)
      t.eq(trace.mapping_status, "rejected")
      t.eq(trace.final_status, "rejected")
      t.eq(trace.aggregate_status, "blocked")
      t.eq(trace.rejection_reason, "host-has-no-authorized-execution-mapping")
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

  test_malformed_external_execution_mapping_fails_closed_with_explicit_reason = function()
    local proposed = external_cases()[1]
    local context = support.new({
      external_proposed_cases = { proposed },
      external_case_mappings = {
        {
          proposed_case_id = proposed.id, case_id = proposed.id, kind = "cli",
          argv = { "bash", "-c", "node cli.js --version" }, timeout_seconds = 10,
          assertions = { { type = "exit-code", expected = 0 } },
        },
      },
    })
    local ok, err = pcall(function()
      context:run_lifecycle()
      t.eq(context.terminal.status, "blocked")
      t.eq(#context.target_effects, 0)
      local mapping = context.store:load(
        context.request.structured_execution.external_case_mapping_ref).value
      local entry = find_case(mapping.entries, proposed.id)
      t.eq(entry.status, "rejected")
      t.eq(entry.rejection_reason, "host-execution-mapping-is-malformed-or-unsupported")
      local aggregate = context.store:load(context.request.publication.aggregate_report_ref).value
      local trace = find_case(aggregate.external_case_traceability, proposed.id)
      t.eq(trace.final_status, "rejected")
      t.eq(trace.aggregate_status, "blocked")
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,

}
