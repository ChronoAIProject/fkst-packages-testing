local cleanup_state = require("cleanup_state")
local t = fkst.test

local function state()
  return {
    request = {
      run_id = "cleanup-state-run",
      repository = {
        slug = "owner/repo",
        url = "https://github.com/owner/repo.git",
        commit_sha = string.rep("1", 40),
      },
      environment_start = { artifact_root = ".testing/runs/cleanup-state-run/environment" },
      trace_id = "trace-cleanup-state",
      dedup_key = "dedup-cleanup-state",
    },
    digests = {},
  }
end

local deps = {
  copy = function(value) return value end,
  digest = function() return string.rep("a", 64) end,
  load_bound = function()
    return {
      status = "pending",
      operation_id = "cleanup-state-run",
      artifact_root = ".testing/runs/cleanup-state-run/environment",
      trace_id = "trace-cleanup-state",
      dedup_key = "dedup-cleanup-state",
    }
  end,
  environment_contract = { validate_cleanup_receipt = function() return true end },
  prepare_finalization = function() error("must not finalize") end,
  save = function() return true end,
}

return {
  test_missing_cleanup_receipt_fails_closed = function()
    t.raises(function()
      cleanup_state.accept(state(), { cleanup_receipt_ref = nil }, {}, deps)
    end)
  end,

  test_nonterminal_cleanup_status_fails_closed = function()
    t.raises(function()
      cleanup_state.accept(state(), {
        cleanup_receipt_ref = { kind = "artifact", ref = ".testing/runs/cleanup-state-run/cleanup.json" },
        cleanup_status = "pending",
      }, {}, deps)
    end)
  end,
}
