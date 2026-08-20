local evidence_contract = require("contract.testing_evidence_manifest")
local json_codec = require("testing_runtime.json")
local results_contract = require("contract.testing_results")
local support = require("test_support.canonical_workflow_qa")
local supervisor = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local function artifact(context, path)
  local value = context.store:load(path)
  if value == nil then error("canonical browser artifact is unavailable: " .. path) end
  return value
end

local function find_case(module_plan, case_id)
  for _, module in ipairs(module_plan.modules or {}) do
    for _, case in ipairs(module.cases or {}) do
      if case.id == case_id then return case end
    end
  end
end

local function assert_public_artifacts_are_sanitized(context, paths)
  local encoded = {}
  for _, path in ipairs(paths) do encoded[#encoded + 1] = artifact(context, path).raw end
  local body = table.concat(encoded, "\n")
  for _, forbidden in ipairs({
    "password=", "secret=", "token=", "Set-Cookie", "Authorization", "<html", "querySelector",
    context.temp_root, context.workspace_root, "primary-identity", "primary-secret",
  }) do
    t.eq(body:find(forbidden, 1, true), nil)
  end
end

return {
  test_canonical_browser_case_runs_through_durable_generic_host_lifecycle = function()
    local context = support.new({
      scenario = "canonical-browser",
      publication_channel = "filesystem-dry-run-v1",
    })
    local ok, err = pcall(function()
      local lifecycle = context:run_lifecycle()
      local execution_root = context.request.structured_execution.artifact_root
      t.eq(execution_root, context.artifact_root)
      t.eq(context.request.structured_execution.structured_plan_ref, context.artifact_root .. "/structured-plan.json")
      t.eq(context.request.structured_execution.grant_ref, context.artifact_root .. "/browser-grant.json")
      local reviewed_plan_path = context.request.structured_execution.structured_plan_ref
      local plan_path = execution_root .. "/test-plan.json"
      local result_set_path = execution_root .. "/case-result-set.json"
      local compatibility_path = execution_root .. "/case-results.json"
      local manifest_path = execution_root .. "/evidence-manifest.json"
      local receipt_path = execution_root .. "/browser-agent-execution.json"
      local metadata_path = execution_root .. "/metadata.json"

      t.eq(context.testing_design_invocations, 1)
      t.eq(context.testing_design_runtime_path, "packages/testing-design/bin/testing-design-runtime.js")
      local module_plan = artifact(context, context.workflow_state.artifacts.module_plan_ref).value
      local reviewed_case = find_case(module_plan, "existing-user-login")
      t.is_true(type(reviewed_case) == "table")
      t.eq(reviewed_case.review_status, "executable")

      local plan_artifact = artifact(context, plan_path)
      local plan = plan_artifact.value
      t.eq(plan.schema, "testing-structured-plan.v2")
      t.eq(plan.execution_mode, "agentic-browser")
      t.eq(#plan.cases, 1)
      t.eq(plan.cases[1].case_id, "existing-user-login")
      t.eq(plan.cases[1].kind, "browser")
      t.eq(#plan.cases[1].completion_assertions, 4)
      t.eq(#plan.residual_risk_case_ids, 0)

      t.eq(context.last_browser_execution_request.environment_receipt_ref,
        context.artifact_root .. "/environment-receipt-ready.json")
      t.eq(context.last_browser_execution_request.reviewed_plan_ref,
        context.artifact_root .. "/structured-plan.json")
      t.eq(context.last_browser_execution_request.browser_grant_ref,
        context.artifact_root .. "/browser-grant.json")
      t.eq(context.last_browser_execution_request.artifact_root, context.artifact_root)
      t.eq(context.browser_grant_claims, 1)
      t.eq(#context.browser_effects, 1)
      t.eq(context.browser_effects[1].kind, "click")
      t.eq(context.browser_effects[1].handle, "a1")
      t.eq(context.browser_effects[1].turn, 1)
      local grant = artifact(context, context.request.structured_execution.grant_ref).value
      t.eq(grant.schema, "testing-runner.ai-browser-control.grant.v1")
      t.eq(grant.grant_id, "browser-grant-1")
      t.eq(grant.target_id, "target-1")
      t.eq(grant.max_uses, 1)

      local receipt = artifact(context, receipt_path).value
      t.eq(receipt.status, "passed")
      t.eq(#receipt.steps, 1)
      t.eq(receipt.steps[1].action.kind, "click")
      t.eq(receipt.steps[1].after.origin, "http://127.0.0.1:43119")
      t.eq(receipt.steps[1].after.path, "/callback")
      t.eq(receipt.completion.callback_observed, true)
      t.eq(receipt.completion.process_exit_zero, true)
      t.eq(receipt.completion.whoami_succeeded, true)
      t.eq(receipt.completion.status_authenticated, true)

      local result_set_artifact = artifact(context, result_set_path)
      local manifest_artifact = artifact(context, manifest_path)
      local result_set = result_set_artifact.value
      local manifest = manifest_artifact.value
      local authorities = results_contract.plan_assertion_authorities(
        plan, { kind = "artifact", ref = plan_path }, plan_artifact.digest)
      results_contract.validate_case_result_set(result_set, authorities, manifest,
        support.sha256_bytes, { artifact_root = execution_root })
      evidence_contract.validate(manifest, result_set, support.sha256_bytes,
        { artifact_root = execution_root })
      t.eq(result_set.evidence_manifest_ref.sha256, manifest_artifact.digest)
      t.eq(result_set.evidence_manifest_artifact_sha256, manifest_artifact.digest)
      t.eq(result_set.evidence_manifest_sha256, manifest.canonical_sha256)
      t.is_true(result_set.evidence_manifest_sha256 ~= result_set.evidence_manifest_artifact_sha256)
      t.eq(result_set.cases[1].execution_status, "passed")
      t.eq(result_set.cases[1].classification, "deterministic")
      t.eq(#result_set.cases[1].assertions, 4)
      for index, assertion in ipairs(result_set.cases[1].assertions) do
        t.eq(assertion.assertion_id, plan.cases[1].completion_assertions[index].assertion_id)
        t.eq(assertion.required, true)
        t.eq(assertion.status, "passed")
        t.eq(assertion.classification, "deterministic")
      end
      t.eq(artifact(context, compatibility_path).value.schema, "testing-case-result-set.v2")
      t.is_true(support.equal(artifact(context, compatibility_path).value, result_set))

      local cleanup = artifact(context, context.terminal.cleanup_receipt_ref).value
      t.eq(cleanup.schema, "environment-factory.cleanup-receipt.v1")
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      local aggregate = artifact(context, context.request.publication.aggregate_report_ref).value
      t.eq(aggregate.schema, "test-publication.qa-aggregate-report.v1")
      t.eq(aggregate.status, "passed")
      t.eq(aggregate.finalization_kind, "full")
      t.eq(aggregate.counts.planned, 1)
      t.eq(aggregate.counts.executed, 1)
      t.eq(aggregate.counts.passed, 1)
      t.eq(aggregate.counts.failed, 0)
      t.eq(aggregate.residual_risks, 0)
      t.eq(aggregate.cleanup_receipt_ref, context.terminal.cleanup_receipt_ref)
      t.eq(context.terminal_records, 1)

      assert_public_artifacts_are_sanitized(context, {
        plan_path, receipt_path, result_set_path, compatibility_path, manifest_path, metadata_path,
        context.request.publication.aggregate_report_ref, context.request.publication.terminal_summary_ref,
      })

      local result_bytes = result_set_artifact.raw
      local manifest_bytes = manifest_artifact.raw
      local result_writes = context.store:write_count(result_set_path)
      local manifest_writes = context.store:write_count(manifest_path)
      local publication_count = context.publication_count
      local terminal_records = context.terminal_records
      local browser_observations = context.browser_observations
      local browser_effects = #context.browser_effects

      context:replace_browser_process()
      local fresh_controller = supervisor.load_package(
        context.project_root, "testing-runner", "ai_browser_control")
      local replay = fresh_controller.result_payload(
        context.last_browser_execution_request, context.ai_browser_runtime)
      t.eq(replay.status, "passed")
      t.eq(replay.native_summary.replayed, true)
      local rediscovered = context:run_lifecycle()
      t.eq(rediscovered.no_op, true)
      local publication_replay = lifecycle.publication.prepare_final_report(
        context.workflow_state.finalization_request, context.publication_runtime)
      t.eq(publication_replay.replayed, true)
      t.eq(publication_replay.status, "published")

      t.eq(artifact(context, result_set_path).raw, result_bytes)
      t.eq(artifact(context, manifest_path).raw, manifest_bytes)
      t.eq(context.store:write_count(result_set_path), result_writes)
      t.eq(context.store:write_count(manifest_path), manifest_writes)
      t.eq(context.publication_count, publication_count)
      t.eq(context.terminal_records, terminal_records)
      t.eq(context.browser_observations, browser_observations)
      t.eq(#context.browser_effects, browser_effects)
      t.eq(context.browser_grant_claims, 1)
    end)
    context:cleanup()
    if not ok then error(err, 0) end
  end,
}
