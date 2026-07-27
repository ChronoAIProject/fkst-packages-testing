local durable = require("host_durable_workflow_qa")
local saga = require("workflow.saga")
local supervisor = require("host_workflow_qa_supervisor")

local spec = {
  consumes = { "durable_workflow_qa_start" },
  stall_window = "10m",
  retry = false,
}

local function payload_for(event)
  local payload = event.payload or {}
  if payload.path == nil then return payload end
  local handle = assert(io.open(payload.path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return json.decode(body)
end

local function act(event)
  local payload = payload_for(event)
  local pending = durable.list_pending(payload.project_root, payload.durable_root, payload.limit)
  for _, context in ipairs(pending) do
    local result = supervisor.run(context, payload.project_root)
    log.info("generic-host dept=workflow_qa_supervisor tag=" .. (result.no_op and "NOOP" or "COMPLETE")
      .. " run_id=" .. tostring(context.run_id))
  end
  if #pending == 0 then
    log.info("generic-host dept=workflow_qa_supervisor tag=NOOP pending_runs=0")
  end
end

return saga.department(spec, { done = function() return false end, act = act, name = "workflow_qa_supervisor" })
