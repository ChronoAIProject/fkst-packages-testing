local M = {}

local required = {
  "load_state", "load_run", "load_run_by_id", "list_pending_runs", "save_state",
  "load_artifact", "write_artifact", "artifact_digest",
}

function M.production()
  local ports = _G.workflow_qa_runtime
  for _, name in ipairs(required) do
    if type(ports) ~= "table" or type(ports[name]) ~= "function" then
      error("workflow-qa: runtime-port-unavailable: " .. name)
    end
  end
  return ports
end

function M.resolve(ports)
  if ports == nil then return M.production() end
  for _, name in ipairs(required) do
    if type(ports[name]) ~= "function" then error("workflow-qa: invalid-runtime: " .. name) end
  end
  return ports
end

return M
