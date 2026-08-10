local M = {}

function M.build(deps)
  local artifact_summary = deps.artifact_summary
  local checkpoint_receipt = deps.checkpoint_receipt
  local checkpoints = deps.checkpoints
  local contract = deps.contract
  local core = deps.core
  local digest = deps.digest
  local drive_to_grant = deps.drive_to_grant
  local execution_result = deps.execution_result
  local expect_failure = deps.expect_failure
  local finalized = deps.finalized
  local fixture = deps.fixture
  local grant_result = deps.grant_result
  local module_terminal = deps.module_terminal
  local plan_result = deps.plan_result
  local pointer = deps.pointer
  local ready_result = deps.ready_result
  local release_checkpoint = deps.release_checkpoint
  local runtime = deps.runtime
  local t = deps.t

  local cases = {}

  cases.blocked_environment_summary_cleanup_and_publication_fail_closed = function()
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local blocked = finalized(request, put)
      blocked.status = "blocked"
      blocked.failure_class = "provisioning-failed"
      blocked.environment_receipt_ref = pointer(request.environment_start.artifact_root .. "/environment-receipt-blocked.json")
      local actions = core.handle_environment_result(blocked, request, ports)
      t.eq(actions[1].queue, "test-publication.qa_checkpoint_request")
      t.eq(state().terminal_status, "blocked")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 0), request, ports)
      local summary = artifact_summary(request, 0, put)
      summary.status = "blocked"
      local actions = core.handle_artifact_summary(summary, request, ports)
      t.eq(actions[1].queue, "environment-factory.environment_finalize")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 0), request, ports)
      local summary = artifact_summary(request, 0, put)
      summary.status = "blocked"
      state().environment_result = nil
      expect_failure("cleanup-unavailable", function() core.handle_artifact_summary(summary, request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      core.handle_environment_result(ready_result(request, put), request, ports)
      state().phase = "cleanup-pending"
      local cleanup = finalized(request, put)
      cleanup.operation_id = "foreign"
      expect_failure("foreign-cleanup-result", function() core.handle_cleanup_result(cleanup, request, ports) end)
      cleanup = finalized(request, put)
      cleanup.cleanup_status = "incomplete"
      cleanup.cleanup_receipt_ref = pointer(request.environment_start.artifact_root .. "/cleanup-receipt-incomplete.json")
      expect_failure("cleanup-unverified", function() core.handle_cleanup_result(cleanup, request, ports) end)
    end
  end

  cases.remaining_workflow_identity_grant_and_publication_boundaries = function()
    local function expect_dedup_rejection(handler, payload, request, ports, invalid_keys)
      for _, dedup_key in ipairs(invalid_keys) do
        local rejected = {}
        for key, value in pairs(payload) do rejected[key] = value end
        rejected.dedup_key = dedup_key == false and nil or dedup_key
        t.eq(pcall(handler, rejected, request, ports), false)
      end
    end

    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      state().phase = "execution-grant-pending"
      local blocked = grant_result(request, put)
      blocked.status = "blocked"
      blocked.grant_ref = nil
      blocked.grant_sha256 = nil
      blocked.failure_class = "authorization-blocked"
      local actions = core.handle_grant_result(blocked, request, ports)
      t.eq(actions[1].queue, "environment-factory.environment_finalize")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local result = ready_result(request, put)
      result.dedup_key = "foreign"
      expect_failure("foreign-result", function() core.handle_environment_result(result, request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      local root_invalid = {
        false, "foreign", request.dedup_key .. "/terminal", request.dedup_key .. "/other",
      }
      expect_dedup_rejection(core.handle_plan_result, plan_result(request, put),
        request, ports, root_invalid)
      expect_dedup_rejection(core.handle_grant_result, grant_result(request, put),
        request, ports, root_invalid)
      expect_dedup_rejection(core.handle_execution_result, execution_result(request, 0),
        request, ports, root_invalid)
      expect_dedup_rejection(core.handle_artifact_summary, artifact_summary(request, 0, put),
        request, ports, root_invalid)
      expect_dedup_rejection(core.handle_module_terminal, module_terminal(request, put), request, ports,
        { false, "foreign", request.dedup_key, request.dedup_key .. "/other" })
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local result = ready_result(request, put)
      core.handle_environment_result(result, request, ports)
      local replay = core.handle_environment_result(result, request, ports)
      t.eq(replay[1].queue, "test-publication.qa_checkpoint_request")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local blocked = finalized(request, put)
      blocked.status = "blocked"
      blocked.failure_class = "provisioning-failed"
      blocked.environment_receipt_ref = pointer(
        request.environment_start.artifact_root .. "/environment-receipt-blocked.json")
      blocked.cleanup_status = "incomplete"
      blocked.cleanup_receipt_ref = pointer(
        request.environment_start.artifact_root .. "/cleanup-receipt-incomplete.json")
      expect_failure("cleanup-unverified", function()
        core.handle_environment_result(blocked, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local original_write = ports.write_artifact
      ports.write_artifact = function(path, value)
        if path == request.publication.terminal_summary_ref then return false end
        return original_write(path, value)
      end
      local blocked = finalized(request, put)
      blocked.status = "blocked"
      blocked.failure_class = "provisioning-failed"
      blocked.environment_receipt_ref = pointer(
        request.environment_start.artifact_root .. "/environment-receipt-blocked.json")
      expect_failure("terminal-summary-write-failed", function()
        core.handle_environment_result(blocked, request, ports)
      end)
    end
    for _, mode in ipairs({ "structured-api-cli", "agentic-browser" }) do
      local request = fixture()
      local ports, state, put, artifacts = runtime(request)
      drive_to_grant(request, ports, state, put, mode)
      state().phase = "execution-grant-pending"
      local result = grant_result(request, put, mode)
      if mode == "structured-api-cli" then
        artifacts[result.grant_ref].value.plan_sha256 = digest("0")
      else
        artifacts[result.grant_ref].value.reviewed_plan_sha256 = digest("0")
      end
      expect_failure("foreign-grant-result", function()
        core.handle_grant_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      state().phase = "execution-grant-pending"
      state().execution_mode = "unknown"
      local result = grant_result(request, put)
      expect_failure("unsupported-execution-mode", function()
        core.handle_grant_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state = runtime(request)
      core.start(request, ports)
      local pending = state().active_checkpoint
      local receipt = checkpoint_receipt(request, pending)
      receipt.schema = "other"
      expect_failure("foreign-publication-receipt", function()
        core.handle_publication_receipt(receipt, request, ports)
      end)
      receipt.schema = "test-publication.qa-publication-receipt.v2"
      state().active_checkpoint = nil
      expect_failure("no matching checkpoint lease", function()
        core.handle_publication_receipt(receipt, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      state().active_checkpoint = nil
      state().phase = "publication-pending"
      state().finalization_request = nil
      put(request.publication.aggregate_report_ref, { schema = "aggregate" }, digest("f"))
      local aggregate = checkpoints.aggregate_expectation(state(), digest("f"))
      local receipt = checkpoint_receipt(request, aggregate)
      expect_failure("aggregate-finalization-unavailable", function()
        core.handle_publication_receipt(receipt, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      local replay = core.handle_interrupt({
        schema = contract.schemas.interrupt, interruption = "timed-out",
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      }, ports)
      t.eq(replay[1].queue, "testing-runner.structured_execution_request")
      state().phase = "cleanup-pending"
      replay = core.handle_interrupt({
        schema = contract.schemas.interrupt, interruption = "timed-out",
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      }, ports)
      t.eq(replay[1].queue, "testing-runner.structured_execution_request")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 1), request, ports)
      local checkpoint = core.handle_artifact_summary(artifact_summary(request, 1, put), request, ports)
      t.eq(checkpoint[1].queue, "test-publication.qa_checkpoint_request")
      release_checkpoint(request, ports, state, "test-publication.defect_preparation_request")
      local receipt_ref = request.publication.defect_receipt_ref
      put(receipt_ref, { schema = "test-publication.defect-publication-receipt.v1" }, digest("9"))
      local defect_checkpoint = core.handle_defect_terminal({
        schema = "test-publication.defect-publication-terminal.v1", status = "published",
        receipt_ref = receipt_ref, receipt_sha256 = digest("9"), published_count = 1,
        source_ref = { kind = "workflow-qa", ref = request.run_id },
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      }, request, ports)
      t.eq(defect_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
      release_checkpoint(request, ports, state, "environment-factory.environment_finalize")
      core.handle_cleanup_result(finalized(request, put), request, ports)
      t.eq(state().finalization_request.defect_publication_receipt_ref, receipt_ref)
      t.eq(state().finalization_request.defect_publication_receipt_sha256, digest("9"))
    end
  end

  return cases
end

return M
