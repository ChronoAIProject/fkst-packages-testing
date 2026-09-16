local M = {}

function M.build(deps)
  local cleanup_incomplete = deps.cleanup_incomplete
  local core = deps.core
  local digest = deps.digest
  local expect_failure = deps.expect_failure
  local fixture = deps.fixture
  local ready_result = deps.ready_result
  local release_checkpoint = deps.release_checkpoint
  local runtime = deps.runtime
  local t = deps.t
  local cases = {}

  local function setup()
    local request = fixture()
    local ports, state, put, artifacts = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    core.handle_environment_result(ready_result(request, put), request, ports)
    state().phase = "cleanup-pending"
    return request, ports, state, put, artifacts
  end

  cases.incomplete_cleanup_becomes_durable_non_publishable_blocked_state = function()
    local request, ports, state, put = setup()
    state().pending_actions = { { queue = "environment-factory.environment_finalize", payload = {} } }
    local blocked = cleanup_incomplete(request, put)
    local actions = core.handle_cleanup_result(blocked, request, ports)
    t.eq(#actions, 0)
    t.eq(state().phase, "cleanup-blocked")
    t.eq(state().terminal_status, "blocked")
    t.eq(#state().pending_actions, 0)
    t.eq(state().cleanup_blocked.reason, "cleanup-incomplete")
    t.eq(state().cleanup_blocked.cleanup_receipt_sha256, digest("f"))
    t.eq(#state().cleanup_blocked.remaining_resources, 1)
    t.eq(#state().cleanup_blocked.worker_home_retention, 1)
    t.eq(state().cleanup_blocked.worker_home_retention[1].ledger_id, digest("8"))
    t.eq(state().cleanup_blocked.worker_home_retention[1].resource_detail_sha256, digest("1"))
    t.eq(state().digests[request.environment_start.artifact_root
      .. "/worker-home-retention.json"], digest("1"))
    t.eq(state().finalization_request, nil)
    t.eq(state().artifacts.terminal_summary_ref, nil)
    t.eq(#core.redrive({ run_id = request.run_id }, ports), 0)
    t.eq(#core.handle_cleanup_result(blocked, request, ports), 0)
  end

  cases.incomplete_cleanup_receipt_binding_and_status_fail_closed = function()
    local mutations = {
      function(blocked) blocked.cleanup_receipt_ref = nil end,
      function(blocked, artifacts) artifacts[blocked.cleanup_receipt_ref.ref].value.status = "complete" end,
      function(blocked, artifacts) artifacts[blocked.cleanup_receipt_ref.ref].value.operation_id = "foreign" end,
      function(blocked, artifacts)
        local receipt = artifacts[blocked.cleanup_receipt_ref.ref].value
        artifacts[receipt.remaining_resources[1].resource_detail_ref.ref].digest = digest("2")
      end,
      function(blocked, artifacts)
        local receipt = artifacts[blocked.cleanup_receipt_ref.ref].value
        artifacts[receipt.remaining_resources[1].resource_detail_ref.ref].value.operation_id = "foreign"
      end,
      function(blocked, artifacts)
        local receipt = artifacts[blocked.cleanup_receipt_ref.ref].value
        artifacts[receipt.remaining_resources[1].resource_detail_ref.ref].value.repository.commit_sha =
          string.rep("b", 40)
      end,
      function(blocked, artifacts)
        artifacts[blocked.cleanup_receipt_ref.ref].value.remaining_resources[1].remaining_count = 2
      end,
    }
    local expected = {
      "contract.environment-factory", "cleanup-status-mismatch", "cleanup receipt binding differs",
      "worker-home retention digest differs", "worker-home retention binding differs",
      "worker-home retention binding differs", "worker-home retention binding differs",
    }
    for index, mutate in ipairs(mutations) do
      local request, ports, _, put, artifacts = setup()
      local blocked = cleanup_incomplete(request, put)
      mutate(blocked, artifacts)
      expect_failure(expected[index], function() core.handle_cleanup_result(blocked, request, ports) end)
    end
  end

  return cases
end

return M
