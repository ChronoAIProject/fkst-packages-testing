local durable = require("host_durable_workflow_qa")
local saga = require("workflow.saga")

local spec = {
  consumes = { "durable_workflow_qa_start" },
  produces = { "local-qa-host-adapter.qa_run_request", "workflow-qa.workflow_qa_tick" },
  stall_window = "2m",
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

local function validate(payload)
  if type(payload) ~= "table" then error("generic-host: durable workflow trigger must be a table") end
  local allowed = { schema = true, project_root = true, durable_root = true, limit = true }
  for key, _ in pairs(payload) do
    if allowed[key] ~= true then error("generic-host: unsupported durable workflow trigger field " .. tostring(key)) end
  end
  if payload.schema ~= "generic-host.durable-workflow-qa-trigger.v1" then
    error("generic-host: durable workflow trigger schema is invalid")
  end
  if type(payload.project_root) ~= "string" or payload.project_root:sub(1, 1) ~= "/" then
    error("generic-host: durable workflow project_root must be absolute")
  end
  local configured_project_root = os.getenv("FKST_GENERIC_HOST_PROJECT_ROOT")
  if configured_project_root == nil or configured_project_root ~= payload.project_root then
    error("generic-host: durable workflow trigger must use the configured Host project root")
  end
  if type(payload.durable_root) ~= "string" or payload.durable_root:sub(1, 1) ~= "/" then
    error("generic-host: durable workflow durable_root must be absolute")
  end
  local configured_root = os.getenv("FKST_GENERIC_HOST_DURABLE_ROOT") or os.getenv("FKST_DURABLE_ROOT")
  if configured_root == nil or configured_root ~= payload.durable_root then
    error("generic-host: durable workflow trigger must use the configured Host durable root")
  end
  local limit = payload.limit == nil and 32 or tonumber(payload.limit)
  if limit == nil or limit < 1 or limit > 64 or limit ~= math.floor(limit) then
    error("generic-host: durable workflow limit must be from 1 to 64")
  end
  payload.limit = limit
  return payload
end

local function act(event)
  local payload = validate(payload_for(event))
  local pending = durable.list_pending(payload.project_root, payload.durable_root, payload.limit)
  if #pending == 0 then
    log.info("generic-host dept=workflow_qa_supervisor tag=NOOP pending_runs=0")
    return
  end
  log.info("generic-host dept=workflow_qa_supervisor tag=DISPATCH pending_runs=" .. tostring(#pending))
  for _, context in ipairs(pending) do
    local action, route = durable.supervisor_action(context)
    if action ~= nil then
      log.info("generic-host dept=workflow_qa_supervisor tag=" .. string.upper(route)
        .. "_RUN run_id=" .. context.run_id)
      raise(action.queue, action.payload)
    else
      log.info("generic-host dept=workflow_qa_supervisor tag=INTAKE_PENDING run_id=" .. context.run_id)
    end
  end
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "workflow_qa_supervisor",
})
