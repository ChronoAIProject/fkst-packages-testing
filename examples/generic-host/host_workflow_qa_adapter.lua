local adapter = require("testing_runtime.workflow_qa_host_adapter")
local runtime = require("testing_runtime.generic_host_workflow_qa")

return adapter.new({
  error_prefix = "generic-host",
  default_ports = function()
    local ports = _G.generic_host_workflow_qa_runtime
    if ports == nil and runtime.configured() then ports = runtime.production() end
    return ports
  end,
})
