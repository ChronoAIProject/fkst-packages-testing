local host_adapter = require("testing_runtime.workflow_qa_host_adapter")
local durable_runtime = require("testing_runtime.generic_host_workflow_qa")

local function default_ports()
  local ports = _G.local_qa_workflow_qa_runtime
  if ports == nil and durable_runtime.configured() then
    ports = durable_runtime.production()
    _G.local_qa_workflow_qa_runtime = ports
  end
  return ports
end

return host_adapter.new({
  error_prefix = "local-qa-host",
  default_ports = default_ports,
})
