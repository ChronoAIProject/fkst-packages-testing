local error_facts = require("contract.error_facts")
local workflow_codex = require("workflow.codex")
local workflow_logging = require("workflow.logging")
local run_module_loop = require("departments.run_module_loop.main")
local t = fkst.test

local function with_log_error(fn)
  local captured = {}
  local previous = log.error
  log.error = function(message)
    table.insert(captured, tostring(message))
  end
  local ok, result = pcall(fn)
  log.error = previous
  if not ok then error(result, 0) end
  return captured, result
end

return {
  test_error_envelope_builder_preserves_dynamic_classification = function()
    local message = error_facts.error_message("testing-runner", "fixture-failure", "forced failure")
    t.eq(message, "testing-runner: fixture-failure: forced failure")
    t.eq(error_facts.error_class_from_message(message), "fixture-failure")
  end,

  test_failure_wrapper_logs_structured_fact_and_rethrows = function()
    local captured = with_log_error(function()
      local wrapped = workflow_logging.wrap_pipeline_failure("testing-runner.run_module_loop", function()
        error("testing-runner: fixture-failure: forced failure")
      end)
      local ok, err = pcall(wrapped, {
        queue = "module_test_request",
        attempt = 3,
        terminal = false,
        payload = {
          run_id = "run-42",
          source_ref = { kind = "test", ref = "workflow-failure-surface" },
        },
      })
      t.eq(ok, false)
      t.is_true(tostring(err):find("testing-runner: fixture-failure: forced failure", 1, true) ~= nil)
    end)
    t.eq(#captured, 1)
    t.is_true(captured[1]:find("dept=testing-runner.run_module_loop", 1, true) ~= nil)
    t.is_true(captured[1]:find("proposal_id=run-42", 1, true) ~= nil)
    t.is_true(captured[1]:find("error_class=fixture-failure", 1, true) ~= nil)
    t.is_true(captured[1]:find("source_ref=test:workflow-failure-surface", 1, true) ~= nil)
    t.is_true(captured[1]:find("attempt=3", 1, true) ~= nil)
  end,

  test_retry_opt_out_remains_explicit = function()
    t.eq(run_module_loop.spec.retry, false)
  end,

  test_public_codex_facade_dispatches_through_internal_owner = function()
    local previous_runs = fkst.codex_runs
    local previous_spawn = spawn_codex_sync
    fkst.codex_runs = function() return { running = {} } end
    spawn_codex_sync = function(opts) return opts end
    local ok, result = pcall(function()
      return workflow_codex.dispatch({
        role = "testing-ai-author",
        proposal_id = "proposal-42",
        dedup_key = "dedup-42",
      }, {
        sync = true,
        prompt = "review",
      })
    end)
    fkst.codex_runs = previous_runs
    spawn_codex_sync = previous_spawn
    if not ok then error(result, 0) end
    t.eq(result.role, "testing-ai-author")
    t.eq(result.proposal_id, "proposal-42")
    t.eq(result.dedup_key, "dedup-42")
    t.eq(result.prompt, "review")
  end,
}
