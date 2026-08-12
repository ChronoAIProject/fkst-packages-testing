local durable = require("host_durable_workflow_qa")
local support = require("host_canonical_workflow_qa")
local supervisor_support = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local function with_context(options, fn)
  local context = support.new(options)
  local ok, result = pcall(fn, context)
  context:cleanup()
  if not ok then error(result, 0) end
end

return {
  test_local_qa_startup_persists_public_action_once_then_redrives = function()
    with_context({
      scenario = "downstream-inventory", durable = true, prepare_execution_grant_pending = false,
    }, function(context)
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local action, route = durable.supervisor_action(recovered)
      t.eq(route, "intake")
      t.eq(action.queue, "local-qa-host-adapter.qa_run_request")
      t.is_true(support.equal(action.payload, recovered.request))

      local repeated, repeated_route = durable.supervisor_action(
        durable.load(context.project_root, context.durable_root, context.run_id))
      t.eq(repeated_route, "intake")
      t.eq(repeated.queue, "local-qa-host-adapter.qa_run_request")
      t.is_true(support.equal(repeated.payload, action.payload))
      t.eq(#recovered.records:list("generic-host/local-qa-startup-outbox"), 1)

      supervisor_support.prepare(recovered, context.project_root)
      local redrive, redrive_route = durable.supervisor_action(
        durable.load(context.project_root, context.durable_root, context.run_id))
      t.eq(redrive_route, "redrive")
      t.eq(redrive.queue, "workflow-qa.workflow_qa_tick")
      t.eq(redrive.payload.run_id, context.run_id)
      t.eq(#recovered.records:list("generic-host/local-qa-startup-outbox"), 1)
    end)
  end,

  test_non_local_qa_startup_retains_direct_redrive = function()
    with_context({ durable = true, prepare_execution_grant_pending = false }, function(context)
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local action, route = durable.supervisor_action(recovered)
      t.eq(route, "redrive")
      t.eq(action.queue, "workflow-qa.workflow_qa_tick")
      t.eq(action.payload.run_id, context.run_id)
      t.eq(#recovered.records:list("generic-host/local-qa-intake"), 0)
    end)
  end,
}
