local contract = require("contract.workflow_qa")
local browser_contract = require("contract.browser_control")
local checkpoints = require("checkpoints")
local core = require("core")
local workflow_ports = require("ports")
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
local analysis_result = helpers.analysis_result
local artifact_summary = helpers.artifact_summary
local checkpoint_receipt = helpers.checkpoint_receipt
local copy = helpers.copy
local digest = helpers.digest
local execution_result = helpers.execution_result
local expect_failure = helpers.expect_failure
local finalized = helpers.finalized
local fixture = helpers.fixture
local grant_result = helpers.grant_result
local module_terminal = helpers.module_terminal
local plan_result = helpers.plan_result
local pointer = helpers.pointer
local ready_result = helpers.ready_result
local runtime = helpers.runtime
local workflow_readiness_result = helpers.workflow_readiness_result

local function release_checkpoint(request, ports, state, expected_queue)
  local pending = state().active_checkpoint
  t.is_true(type(pending) == "table")
  local receipt = checkpoint_receipt(request, pending)
  t.eq(ports.write_artifact(receipt.receipt_ref, receipt), true)
  local actions = core.handle_publication_receipt(receipt, request, ports)
  if expected_queue ~= nil then t.eq(actions[1].queue, expected_queue) end
  return actions
end

local function drive_to_browser_pending(request, ports, state, put)
  core.start(request, ports)
  release_checkpoint(request, ports, state, "environment-factory.environment_start")
  core.handle_environment_result(ready_result(request, put), request, ports)
  release_checkpoint(request, ports, state, "testing-design.analysis_request")
  core.handle_analysis_result(analysis_result(request), request, ports)
  return release_checkpoint(request, ports, state, "browser-readiness.browser_readiness_check")
end

local function drive_to_grant(request, ports, state, put, execution_mode)
  local intake = core.start(request, ports)
  t.eq(intake[1].queue, "test-publication.qa_checkpoint_request")
  release_checkpoint(request, ports, state, "environment-factory.environment_start")

  local environment = core.handle_environment_result(ready_result(request, put), request, ports)
  t.eq(environment[1].queue, "test-publication.qa_checkpoint_request")
  release_checkpoint(request, ports, state, "testing-design.analysis_request")

  local design = core.handle_analysis_result(analysis_result(request), request, ports)
  t.eq(design[1].queue, "test-publication.qa_checkpoint_request")
  local readiness = release_checkpoint(request, ports, state, "browser-readiness.browser_readiness_check")
  t.eq(readiness[1].payload.source_ref.kind, "workflow-qa")

  local browser = core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
  t.eq(browser[1].queue, "test-publication.qa_checkpoint_request")
  local module = release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
  t.eq(module[1].payload.preflight_result.status, "ready")

  local closure = core.handle_module_terminal(module_terminal(request, put), request, ports)
  t.eq(closure[1].queue, "test-publication.qa_checkpoint_request")
  release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")

  local grant = core.handle_plan_result(plan_result(request, put, execution_mode), request, ports)
  t.eq(grant[1].queue, "workflow_qa_execution_grant_request")
  t.eq(grant[1].payload.execution_mode, execution_mode or "structured-api-cli")
  return core.handle_grant_result(grant_result(request, put, execution_mode), request, ports)
end

local tests = {
  test_top_level_design_request_receives_persisted_seed_reference = function()
    local request = fixture()
    request.design_module_start.cdp_execution = nil
    request.design_module_start.module_discovery = { schema = "testing-runner.module-discovery.v1", observations = {} }
    local ports, state, put = runtime(request)
    drive_to_browser_pending(request, ports, state, put)
    core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
    local actions = release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
    local module_start = actions[1].payload
    t.eq(module_start.cdp_execution, nil)
    t.eq(module_start.ai_design_loop_request.seed_cases_ref.artifact_pointer,
      state().artifacts.seed_cases_ref.artifact_pointer)
    t.eq(module_start.ai_design_loop_request.seed_cases_ref.artifact_digest,
      state().artifacts.seed_cases_ref.artifact_digest)
  end,

  test_run_traverses_plan_grant_execution_cleanup_and_terminal = function()
    local request = fixture()
    request.publication.channel = "filesystem-dry-run-v1"
    local ports, state, put, artifacts = runtime(request)
    local execution = drive_to_grant(request, ports, state, put)
    t.eq(execution[1].queue, "testing-runner.structured_execution_request")
    t.eq(state().phase, "structured-execution-pending")
    local summarize = core.handle_execution_result(execution_result(request, 0), request, ports)
    t.eq(summarize[1].queue, "test-artifacts.testing_result")
    local execution_checkpoint = core.handle_artifact_summary(artifact_summary(request, 0, put), request, ports)
    t.eq(execution_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "environment-factory.environment_finalize")
    local cleanup_checkpoint = core.handle_cleanup_result(finalized(request, put), request, ports)
    t.eq(cleanup_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(cleanup_checkpoint[1].payload.channel, "filesystem-dry-run-v1")
    local historical_terminal = artifacts[request.publication.terminal_summary_ref].value
    t.eq(historical_terminal.case_result_set_ref, nil)
    t.eq(historical_terminal.evidence_manifest_ref, nil)
    local wrong_stage_receipt = checkpoint_receipt(request, state().active_checkpoint)
    local finalization = release_checkpoint(request, ports, state, "test-publication.qa_finalize_request")
    t.eq(finalization[1].payload.channel, "filesystem-dry-run-v1")
    t.eq(finalization[1].payload.case_result_set_ref, nil)
    t.eq(finalization[1].payload.evidence_manifest_ref, nil)
    t.eq(state().request.publication.channel, "filesystem-dry-run-v1")
    t.eq(state().phase, "publication-pending")
    t.is_true(type(state().finalization_request) == "table")
    t.eq(state().finalization_request.aggregate_report_ref, request.publication.aggregate_report_ref)
    t.eq(wrong_stage_receipt.schema, "test-publication.qa-publication-receipt.v2")
    t.eq(wrong_stage_receipt.run_id, request.run_id)
    t.eq(wrong_stage_receipt.repository.slug, request.repository.slug)
    t.eq(wrong_stage_receipt.trace_id, request.trace_id)
    t.eq(wrong_stage_receipt.dedup_key, request.dedup_key)
    t.is_true(wrong_stage_receipt.stage ~= "aggregate-report")
    local publication_snapshot = {
      phase = state().phase,
      version = state().version,
      finalization_request = copy(state().finalization_request),
      aggregate_receipt = copy(state().aggregate_receipt),
      aggregate_receipt_sha256 = state().aggregate_receipt_sha256,
      aggregate_report_sha256 = state().digests[request.publication.aggregate_report_ref],
      pending_actions = copy(state().pending_actions),
    }
    expect_failure("foreign-publication-receipt: no matching checkpoint lease exists", function()
      core.handle_publication_receipt(wrong_stage_receipt, request, ports)
    end)
    t.eq(state().phase, publication_snapshot.phase)
    t.eq(state().version, publication_snapshot.version)
    t.eq(execution_contract.equal(state().finalization_request,
      publication_snapshot.finalization_request), true)
    t.eq(execution_contract.equal(state().aggregate_receipt,
      publication_snapshot.aggregate_receipt), true)
    t.eq(state().aggregate_receipt_sha256, publication_snapshot.aggregate_receipt_sha256)
    t.eq(state().digests[request.publication.aggregate_report_ref],
      publication_snapshot.aggregate_report_sha256)
    t.eq(execution_contract.equal(state().pending_actions, publication_snapshot.pending_actions), true)
    put(request.publication.aggregate_report_ref, {
      schema = "test-publication.qa-aggregate-report.v1", run_id = request.run_id,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, digest("f"))
    local aggregate = checkpoints.aggregate_expectation(state(), digest("f"))
    local aggregate_receipt = checkpoint_receipt(request, aggregate)
    t.eq(ports.write_artifact(aggregate_receipt.receipt_ref, aggregate_receipt), true)
    local terminal = core.handle_publication_receipt(aggregate_receipt, request, ports)
    t.eq(#terminal, 1)
    t.eq(terminal[1].queue, "workflow_qa_terminal_request")
    t.eq(state().phase, "terminal")
    t.eq(state().version, publication_snapshot.version + 1)
  end,

  test_agentic_browser_plan_routes_only_to_browser_controller = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    local execution = drive_to_grant(request, ports, state, put, "agentic-browser")
    t.eq(execution[1].queue, "testing-runner.ai_browser_control_request")
    t.eq(execution[1].payload.schema, browser_contract.schemas.request)
    t.eq(state().phase, "browser-control-pending")
    t.eq(state().execution_job, "ai-browser-control")
  end,

  test_failed_cases_wait_for_defect_preparation_and_terminal_receipt = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    drive_to_grant(request, ports, state, put)
    core.handle_execution_result(execution_result(request, 1), request, ports)
    local execution_checkpoint = core.handle_artifact_summary(artifact_summary(request, 1, put), request, ports)
    t.eq(execution_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "test-publication.defect_preparation_request")
    t.eq(state().phase, "defects-pending")
    local defect_checkpoint = core.handle_defect_terminal({
      schema = "test-publication.defect-publication-terminal.v1", status = "published",
      receipt_ref = request.publication.defect_receipt_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, request, ports)
    t.eq(defect_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "environment-factory.environment_finalize")
  end,

  test_canonical_artifacts_propagate_through_replay_cleanup_and_finalization = function()
    local request = fixture()
    local ports, state, put, artifacts = runtime(request)
    drive_to_grant(request, ports, state, put)
    core.handle_execution_result(execution_result(request, 1), request, ports)
    local summary = artifact_summary(request, 1, put, true)
    local canonical_plan_ref = summary.native_summary.test_plan_path
    local result_ref = summary.native_summary.case_result_set_path
    local manifest_ref = summary.native_summary.evidence_manifest_path
    local first = core.handle_artifact_summary(summary, request, ports)
    t.eq(state().artifacts.canonical_plan_ref, canonical_plan_ref)
    t.eq(state().digests[canonical_plan_ref], digest("a"))
    t.eq(state().artifacts.case_result_set_ref, result_ref)
    t.eq(state().artifacts.evidence_manifest_ref, manifest_ref)
    t.eq(state().digests[result_ref], digest("4"))
    t.eq(state().digests[manifest_ref], digest("5"))

    local accepted_version = state().version
    artifacts[result_ref].digest = digest("8")
    artifacts[manifest_ref].digest = digest("9")
    local replay = core.handle_artifact_summary(summary, request, ports)
    t.eq(execution_contract.equal(replay, first), true)
    t.eq(state().version, accepted_version)

    local preparation = release_checkpoint(request, ports, state,
      "test-publication.defect_preparation_request")[1].payload
    t.eq(preparation.plan_ref, canonical_plan_ref)
    t.eq(preparation.plan_sha256, digest("a"))
    t.eq(preparation.publication.test_plan_path, canonical_plan_ref)
    t.eq(preparation.case_result_set_ref, result_ref)
    t.eq(preparation.case_result_set_artifact_sha256, digest("4"))
    t.eq(preparation.evidence_manifest_ref, manifest_ref)
    t.eq(preparation.evidence_manifest_artifact_sha256, digest("5"))
    t.eq(preparation.publication.case_result_set_path, result_ref)
    t.eq(preparation.publication.case_result_set_artifact_sha256, digest("4"))
    t.eq(preparation.publication.evidence_manifest_path, manifest_ref)
    t.eq(preparation.publication.evidence_manifest_artifact_sha256, digest("5"))

    core.handle_defect_terminal({
      schema = "test-publication.defect-publication-terminal.v1", status = "published",
      receipt_ref = request.publication.defect_receipt_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_finalize")
    core.handle_cleanup_result(finalized(request, put), request, ports)
    local terminal = artifacts[request.publication.terminal_summary_ref].value
    t.eq(terminal.structured_plan_ref, canonical_plan_ref)
    t.eq(terminal.case_result_set_ref, result_ref)
    t.eq(terminal.evidence_manifest_ref, manifest_ref)
    local final = release_checkpoint(request, ports, state, "test-publication.qa_finalize_request")[1].payload
    t.eq(final.test_plan_ref, canonical_plan_ref)
    t.eq(final.test_plan_sha256, digest("a"))
    t.eq(final.case_result_set_ref, result_ref)
    t.eq(final.case_result_set_artifact_sha256, digest("4"))
    t.eq(final.evidence_manifest_ref, manifest_ref)
    t.eq(final.evidence_manifest_artifact_sha256, digest("5"))
  end,

  test_historical_artifact_summary_omits_canonical_defect_fields = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    drive_to_grant(request, ports, state, put)
    core.handle_execution_result(execution_result(request, 1), request, ports)
    core.handle_artifact_summary(artifact_summary(request, 1, put), request, ports)
    local preparation = release_checkpoint(request, ports, state,
      "test-publication.defect_preparation_request")[1].payload
    t.eq(preparation.case_result_set_ref, nil)
    t.eq(preparation.case_result_set_artifact_sha256, nil)
    t.eq(preparation.evidence_manifest_ref, nil)
    t.eq(preparation.evidence_manifest_artifact_sha256, nil)
    t.eq(preparation.publication.case_result_set_path, nil)
    t.eq(preparation.publication.evidence_manifest_path, nil)
  end,

  test_partial_and_foreign_canonical_paths_fail_before_progression = function()
    local mutations = {
      function(summary)
        summary.native_summary.case_result_set_path = summary.artifact_root .. "/case-result-set.json"
      end,
      function(summary)
        summary.native_summary.case_result_set_path = summary.artifact_root .. "/foreign-result-set.json"
        summary.native_summary.evidence_manifest_path = summary.artifact_root .. "/evidence-manifest.json"
      end,
    }
    for _, mutate in ipairs(mutations) do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 1), request, ports)
      local summary = artifact_summary(request, 1, put)
      mutate(summary)
      local version = state().version
      expect_failure("foreign-artifact-summary", function()
        core.handle_artifact_summary(summary, request, ports)
      end)
      t.eq(state().phase, "artifact-summary-pending")
      t.eq(state().version, version)
      t.eq(state().execution_summary, nil)
      t.eq(state().artifacts.case_result_set_ref, nil)
      t.eq(state().pending_actions[1].queue, "test-artifacts.testing_result")
    end
  end,

  test_foreign_canonical_group_and_persisted_digest_fail_before_progression = function()
    for _, mismatch in ipairs({ "path", "digest" }) do
      local request = fixture()
      local ports, state, put, artifacts = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 1), request, ports)
      local summary = artifact_summary(request, 1, put, true)
      if mismatch == "path" then
        summary.native_summary.case_result_set_path = summary.artifact_root .. "/other.json"
      else
        artifacts[summary.native_summary.case_result_set_path].digest = digest("8")
      end
      local version = state().version
      expect_failure("foreign-artifact-summary", function()
        core.handle_artifact_summary(summary, request, ports)
      end)
      t.eq(state().phase, "artifact-summary-pending")
      t.eq(state().version, version)
    end
  end,

  test_plan_and_grant_redelivery_are_idempotent = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    core.handle_environment_result(ready_result(request, put), request, ports)
    release_checkpoint(request, ports, state, "testing-design.analysis_request")
    core.handle_analysis_result(analysis_result(request), request, ports)
    release_checkpoint(request, ports, state, "browser-readiness.browser_readiness_check")
    core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
    release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
    core.handle_module_terminal(module_terminal(request, put), request, ports)
    release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")
    local first = core.handle_plan_result(plan_result(request, put), request, ports)
    local second = core.handle_plan_result(plan_result(request, put), request, ports)
    t.eq(second[1].queue, first[1].queue)
    core.handle_grant_result(grant_result(request, put), request, ports)
    local replay = core.handle_grant_result(grant_result(request, put), request, ports)
    t.eq(replay[1].queue, "testing-runner.structured_execution_request")
    t.eq(state().phase, "structured-execution-pending")
  end,

  test_claim_and_closed_identity_fail_closed = function()
    local request = fixture()
    request.issue.labels = { "fkst-dev:enabled" }
    t.raises(function() contract.validate_request(request) end)
    request = fixture()
    request.issue.state = "closed"
    t.raises(function() contract.validate_request(request) end)
    request = fixture()
    request.environment_start.repository.commit_sha = string.rep("c", 40)
    t.raises(function() contract.validate_request(request) end)
  end,

  test_contract_rejects_nested_reviewed_design_fields = function()
    local nested_request = fixture()
    nested_request.design_module_start.cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      ai_design_loop_request = copy(nested_request.design_module_start.ai_design_loop_request),
    }
    nested_request.design_module_start.ai_design_loop_request = nil
    t.raises(function() contract.validate_request(nested_request) end)

    local nested_state = fixture()
    nested_state.design_module_start.cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      ai_design_loop_state_ref = {
        artifact_pointer = nested_state.artifact_root .. "/design/ai-design-loop-state.json",
        artifact_digest = "design-state-digest",
      },
    }
    nested_state.design_module_start.ai_design_loop_request = nil
    t.raises(function() contract.validate_request(nested_state) end)

    local duplicated = fixture()
    duplicated.design_module_start.cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      ai_design_loop_request = copy(duplicated.design_module_start.ai_design_loop_request),
    }
    t.raises(function() contract.validate_request(duplicated) end)
  end,

  test_contract_rejects_invalid_reviewed_design_authority = function()
    local invalid_references = {
      { artifact_pointer = "unsafe/state.json", artifact_digest = "design-state-digest" },
      { artifact_pointer = ".testing/runs/workflow-qa-fixture/design/state.json", artifact_digest = "" },
    }
    for _, state_ref in ipairs(invalid_references) do
      local request = fixture()
      request.design_module_start.ai_design_loop_request = nil
      request.design_module_start.ai_design_loop_state_ref = state_ref
      expect_failure("malformed-design: ai-design-loop-state-reference is invalid", function()
        contract.validate_request(request)
      end)
    end

    local invalid_requests = {
      function(value) value.schema = "foreign" end,
      function(value) value.case_budget = 0 end,
    }
    for _, mutate in ipairs(invalid_requests) do
      local request = fixture()
      mutate(request.design_module_start.ai_design_loop_request)
      expect_failure("malformed-design: ai design loop request is invalid", function()
        contract.validate_request(request)
      end)
    end

    local ambiguous = fixture()
    ambiguous.design_module_start.ai_design_loop_state_ref = {
      artifact_pointer = ambiguous.design_module_start.artifact_root .. "/loop/ai-design-loop-state.json",
      artifact_digest = "design-state-digest",
    }
    expect_failure("foreign-design: design module start has ambiguous reviewed-state authority", function()
      contract.validate_request(ambiguous)
    end)

    local foreign_mutations = {
      function(request) request.design_module_start.ai_design_loop_request.trace_id = "foreign-trace" end,
      function(request) request.design_module_start.ai_design_loop_request.dedup_key = "foreign-dedup" end,
      function(request)
        request.design_module_start.ai_design_loop_request.artifact_root = request.artifact_root .. "/foreign-loop"
      end,
    }
    for _, mutate in ipairs(foreign_mutations) do
      local request = fixture()
      mutate(request)
      expect_failure("foreign-design: design loop request differs from the closed run identity", function()
        contract.validate_request(request)
      end)
    end
  end,

  test_contract_rejects_malformed_closed_inputs = function()
    local mutations = {
      function(value) value.repository.url = "https://user@example.invalid/repo.git" end,
      function(value) value.proposed_cases = {} end,
      function(value) value.proposed_cases[1].actions[1].extra = true end,
      function(value) value.proposed_cases[1].actions[1].action = nil end,
      function(value) value.proposed_cases[1].actions[1].target_module_id = "" end,
      function(value) value.proposed_cases[1].actions[1].evidence_pointer = "/tmp/evidence.json" end,
      function(value) value.proposed_cases[1].id = nil end,
      function(value) value.proposed_cases[1].review_status = "approved" end,
      function(value) value.run_id = "" end,
      function(value) value.state_ref = value.artifact_root .. "/other.json" end,
      function(value) value.analysis_request.trace_id = "foreign" end,
      function(value) value.design_module_start.source_ref.ref = "foreign" end,
      function(value) value.structured_execution.grant_ref = ".testing/runs/foreign/grant.json" end,
      function(value) value.publication.aggregate_report_ref = ".testing/runs/foreign/report.json" end,
      function(value) value.publication.channel = "email-v1" end,
      function(value) value.terminal_policy.mode = "package" end,
    }
    for _, mutate in ipairs(mutations) do
      local value = fixture()
      mutate(value)
      expect_failure("contract.workflow-qa:", function() contract.validate_request(value) end)
    end
    expect_failure("malformed-interruption", function()
      contract.validate_interrupt({
        schema = contract.schemas.interrupt,
        interruption = "stop",
        trace_id = "trace",
        dedup_key = "dedup",
      })
    end)
  end,

  test_terminal_contract_accepts_complete_handoff_and_rejects_mutations = function()
    local request = fixture()
    local terminal = {
      schema = contract.schemas.terminal,
      repository = request.repository.slug,
      issue_number = request.issue.number,
      run_id = request.run_id,
      status = "passed",
      counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
      artifact_root = request.artifact_root,
      aggregate_report_ref = request.publication.aggregate_report_ref,
      aggregate_report_sha256 = digest("a"),
      aggregate_publication_receipt_ref = request.artifact_root .. "/publication/aggregate-receipt.json",
      aggregate_publication_receipt_sha256 = digest("b"),
      cleanup_receipt_ref = request.artifact_root .. "/environment/cleanup-receipt.json",
      cleanup_receipt_sha256 = digest("c"),
      terminal_policy = "host",
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    }
    t.eq(contract.validate_terminal(terminal), terminal)

    local mutations = {
      function(value) value.status = "unknown" end,
      function(value) value.counts.failed = -1 end,
      function(value) value.aggregate_report_ref = ".testing/runs/foreign/report.json" end,
      function(value) value.cleanup_receipt_sha256 = "bad" end,
    }
    for _, mutate in ipairs(mutations) do
      local value = copy(terminal)
      mutate(value)
      expect_failure("malformed-terminal", function() contract.validate_terminal(value) end)
    end
  end,

  test_checkpoint_lease_rejects_overlap_and_foreign_receipts = function()
    local request = fixture()
    local ref = request.artifact_root .. "/checkpoint.json"
    local state = {
      request = request,
      phase = "testing",
      digests = { [ref] = digest("d") },
    }
    checkpoints.gate(state, "coverage", "passed", ref, nil, "next", {})
    expect_failure("checkpoint-already-pending", function()
      checkpoints.gate(state, "other", "passed", ref, nil, "next", {})
    end)
    local persisted = {}
    local checkpoint_ports = {
      load_artifact = function(ref) return persisted[ref] end,
    }
    expect_failure("foreign-checkpoint-receipt", function()
      checkpoints.release(state, { stage = "foreign" }, checkpoint_ports)
    end)
    local receipt = checkpoint_receipt(request, state.active_checkpoint)
    persisted[receipt.receipt_ref] = { value = {}, digest = digest("f") }
    expect_failure("checkpoint-receipt-unavailable", function()
      checkpoints.release(state, receipt, checkpoint_ports)
    end)
    persisted[receipt.receipt_ref] = { value = copy(receipt), digest = digest("f") }
    local actions = checkpoints.release(state, receipt, checkpoint_ports)
    t.eq(#actions, 0)
    t.eq(state.phase, "next")
    t.eq(checkpoints.release(state, {}, checkpoint_ports), nil)
  end,

  test_start_fails_closed_at_authorization_and_storage_boundaries = function()
    do
      local request = fixture()
      local ports = runtime(request)
      ports.artifact_digest = function() return "bad" end
      expect_failure("artifact-digest-unavailable", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      artifacts[request.structured_execution.preauthorization_ref] = nil
      expect_failure("artifact-binding-unavailable", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      artifacts[request.environment_start.validation_receipt_ref.ref] = nil
      expect_failure("validation-receipt-unavailable", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports = runtime(request)
      ports.save_state = function() return false end
      expect_failure("state-save-conflict", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports = runtime(request)
      ports.write_artifact = function() return false end
      expect_failure("intake-artifact-write-failed", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      core.start(request, ports)
      artifacts[request.structured_execution.preauthorization_ref].value.profile_sha256 = digest("8")
      artifacts[request.environment_start.validation_receipt_ref.ref].value.profile_sha256 = digest("8")
      expect_failure("authorization-binding-changed", function() core.start(request, ports) end)
    end
  end,

  test_environment_and_browser_results_enforce_owned_bindings = function()
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local result = ready_result(request, put)
      result.operation_id = "foreign"
      expect_failure("foreign-environment-result", function()
        core.handle_environment_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put, artifacts = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local result = ready_result(request, put)
      artifacts[result.environment_receipt_ref.ref].value.repository.commit_sha = string.rep("c", 40)
      expect_failure("environment-readiness-unverified", function()
        core.handle_environment_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      local result = workflow_readiness_result(request)
      result.correlation.attempt_id = "foreign"
      expect_failure("foreign-browser-readiness-result", function()
        core.handle_browser_readiness_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      local result = workflow_readiness_result(request)
      result.status = "blocked"
      for _, session in ipairs(result.sessions) do session.status = "blocked" end
      local cleanup = core.handle_browser_readiness_result(result, request, ports)
      t.eq(cleanup[1].queue, "environment-factory.environment_finalize")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      local original = ports.write_artifact
      ports.write_artifact = function(path, value)
        if path == request.artifact_root .. "/browser-readiness.json" then return false end
        return original(path, value)
      end
      expect_failure("browser-readiness-write-failed", function()
        core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
      end)
    end
  end,

  test_interrupt_and_redrive_respect_durable_phase = function()
    local request = fixture()
    local ports, state = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    local pending = core.handle_interrupt({
      schema = contract.schemas.interrupt,
      interruption = "timed-out",
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    }, ports)
    t.eq(pending[1].queue, "environment-factory.environment_start")
    t.eq(state().interruption_requested, "timed-out")

    local replay = core.redrive({ limit = 1 }, ports)
    t.eq(replay[1].queue, "environment-factory.environment_start")
    for _, limit in ipairs({ 0, 65, 1.5 }) do
      expect_failure("malformed-redrive", function() core.redrive({ limit = limit }, ports) end)
    end
    local original_list = ports.list_pending_runs
    ports.list_pending_runs = function() return "invalid" end
    expect_failure("redrive-unavailable", function() core.redrive({}, ports) end)
    ports.list_pending_runs = original_list
    state().phase = "terminal"
    t.eq(core.redrive({}, ports)[1].queue, "environment-factory.environment_start")
    state().pending_actions = {}
    t.eq(#core.redrive({}, ports), 0)
  end,

  test_redrive_starts_indexed_request_without_state = function()
    local request = fixture()
    local ports, state = runtime(request)
    local replay = core.redrive({ limit = 1 }, ports)
    t.eq(replay[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(state().phase, "checkpoint-pending")
    t.eq(state().request.run_id, request.run_id)
  end,

  test_redrive_can_isolate_one_internal_run = function()
    local request = fixture()
    local ports = runtime(request)
    core.start(request, ports)
    ports.list_pending_runs = function() error("batch listing should not run") end
    local replay = core.redrive({ run_id = request.run_id, limit = 1 }, ports)
    t.eq(replay[1].queue, "test-publication.qa_checkpoint_request")
    for _, run_id in ipairs({ "", "../foreign", string.rep("a", 181) }) do
      expect_failure("malformed-redrive", function()
        core.redrive({ run_id = run_id, limit = 1 }, ports)
      end)
    end
  end,

  test_redrive_rejects_changed_durable_authorization_identity = function()
    local request = fixture()
    local ports, _, _, artifacts = runtime(request)
    core.start(request, ports)
    artifacts[request.structured_execution.preauthorization_ref].value.profile_sha256 = digest("8")
    artifacts[request.environment_start.validation_receipt_ref.ref].value.profile_sha256 = digest("8")
    expect_failure("authorization-binding-changed", function()
      core.redrive({ run_id = request.run_id, limit = 1 }, ports)
    end)
  end,

  test_production_ports_require_and_return_host_runtime = function()
    local request = fixture()
    local ports = runtime(request)
    local previous = _G.workflow_qa_runtime
    _G.workflow_qa_runtime = ports
    t.eq(workflow_ports.production(), ports)
    _G.workflow_qa_runtime = {}
    expect_failure("runtime-port-unavailable", function() workflow_ports.production() end)
    _G.workflow_qa_runtime = previous
  end,

  test_cancelled_run_uses_owned_environment_interrupt_path = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    core.handle_environment_result(ready_result(request, put), request, ports)
    local actions = core.handle_interrupt({
      schema = contract.schemas.interrupt, interruption = "cancelled",
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, ports)
    t.eq(actions[1].queue, "environment-factory.environment_interrupt")
    t.eq(actions[1].payload.interruption, "cancelled")
  end,

  test_replay_and_identity_boundaries_fail_closed = function()
    do
      local request = fixture()
      local ports, state = runtime(request)
      local first = core.start(request, ports)
      local replay = core.start(request, ports)
      t.eq(replay[1].queue, first[1].queue)
      state().request.run_id = "foreign"
      expect_failure("foreign-state", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      artifacts[request.environment_start.validation_receipt_ref.ref].value.trace_id = "foreign"
      expect_failure("authorization-binding-mismatch", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      local result = execution_result(request, 0)
      result.job = "foreign"
      expect_failure("foreign-execution-result", function() core.handle_execution_result(result, nil, ports) end)
      result = execution_result(request, 0)
      result.source_ref.ref = "foreign"
      expect_failure("foreign-result", function() core.handle_execution_result(result, request, ports) end)
    end
    do
      local request = fixture()
      local ports = runtime(request)
      local lookups, original = 0, ports.load_run_by_id
      ports.load_run_by_id = function(run_id) lookups = lookups + 1 return original(run_id) end
      local result = execution_result(request, 0)
      result.source_ref.ref = string.rep("r", 181)
      expect_failure("run-identity-invalid", function() core.handle_execution_result(result, nil, ports) end)
      t.eq(lookups, 0)
      ports.load_run_by_id = function(run_id) lookups = lookups + 1 return request end
      result.source_ref.ref = "run..01"
      expect_failure("state-unavailable", function() core.handle_execution_result(result, nil, ports) end)
      t.eq(lookups, 1)
    end
  end,

  test_environment_event_routes_ready_and_cleanup_results = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    local ready = core.handle_environment_event(ready_result(request, put), ports)
    t.eq(ready[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "testing-design.analysis_request")
    state().phase = "cleanup-pending"
    state().environment_result = ready_result(request, put)
    state().environment_result.status = "ready"
    local cleanup = core.handle_environment_event(finalized(request, put), ports)
    t.eq(cleanup[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(#core.saga_conformance_errors(), 0)
  end,

  test_terminal_handlers_reject_foreign_bindings = function()
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      local result = execution_result(request, 0)
      result.job = "foreign"
      expect_failure("foreign-execution-result", function() core.handle_execution_result(result, request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 0), request, ports)
      local summary = artifact_summary(request, 0, put)
      summary.artifact_root = request.artifact_root
      expect_failure("foreign-artifact-summary", function() core.handle_artifact_summary(summary, request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 1), request, ports)
      core.handle_artifact_summary(artifact_summary(request, 1, put), request, ports)
      release_checkpoint(request, ports, state, "test-publication.defect_preparation_request")
      local payload = {
        schema = "test-publication.defect-publication-terminal.v1", status = "published",
        receipt_ref = "foreign", trace_id = request.trace_id, dedup_key = request.dedup_key,
      }
      expect_failure("receipt pointer differs", function() core.handle_defect_terminal(payload, request, ports) end)
      payload.schema = "foreign"
      expect_failure("publication receipt binding differs", function() core.handle_defect_terminal(payload, request, ports) end)
    end
  end,

  test_module_plan_and_grant_blocked_paths_begin_owned_cleanup = function()
    local function module_pending()
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
      release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
      return request, ports, state, put
    end

    do
      local request, ports, _, put = module_pending()
      local payload = module_terminal(request, put)
      payload.runner_result.schema = "foreign"
      expect_failure("runner result is invalid", function() core.handle_module_terminal(payload, request, ports) end)
    end
    do
      local request, ports, state, put = module_pending()
      local payload = module_terminal(request, put)
      payload.runner_result.status = "blocked"
      local actions = core.handle_module_terminal(payload, request, ports)
      t.eq(actions[1].queue, "environment-factory.environment_finalize")
      t.eq(state().phase, "cleanup-pending")
    end
    do
      local request, ports, _, put = module_pending()
      local payload = module_terminal(request, put)
      payload.module_plan_sha256 = digest("0")
      expect_failure("module plan digest differs", function() core.handle_module_terminal(payload, request, ports) end)
    end
    do
      local request, ports, state, put = module_pending()
      core.handle_module_terminal(module_terminal(request, put), request, ports)
      release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")
      local blocked = plan_result(request, put)
      blocked.status = "blocked"
      blocked.plan_ref = nil
      blocked.plan_sha256 = nil
      blocked.failure_class = "plan-compilation-failed"
      local actions = core.handle_plan_result(blocked, request, ports)
      t.eq(actions[1].queue, "environment-factory.environment_finalize")
    end
    do
      local request, ports, state, put = module_pending()
      core.handle_module_terminal(module_terminal(request, put), request, ports)
      release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")
      local result = plan_result(request, put)
      state().phase = "structured-plan-pending"
      local original = ports.load_artifact
      ports.load_artifact = function(path)
        local artifact = original(path)
        if path == result.plan_ref then artifact.value.repository.commit_sha = string.rep("c", 40) end
        return artifact
      end
      expect_failure("compiled plan binding differs", function() core.handle_plan_result(result, request, ports) end)
    end
  end,

}

local workflow_core_coverage_cases = require("tests.workflow_core_coverage_helpers").build({
  artifact_summary = artifact_summary, checkpoint_receipt = checkpoint_receipt, checkpoints = checkpoints,
  contract = contract, core = core, digest = digest, drive_to_grant = drive_to_grant,
  execution_result = execution_result, expect_failure = expect_failure, finalized = finalized, fixture = fixture,
  grant_result = grant_result, module_terminal = module_terminal, plan_result = plan_result, pointer = pointer,
  ready_result = ready_result,
  release_checkpoint = release_checkpoint, runtime = runtime, t = t,
})
tests.test_blocked_environment_summary_cleanup_and_publication_fail_closed =
  workflow_core_coverage_cases.blocked_environment_summary_cleanup_and_publication_fail_closed
tests.test_remaining_workflow_identity_grant_and_publication_boundaries =
  workflow_core_coverage_cases.remaining_workflow_identity_grant_and_publication_boundaries

return tests
