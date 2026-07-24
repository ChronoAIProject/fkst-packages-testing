local adapter = require("testing_runtime.workflow_qa_host_adapter")

return adapter.new({
  error_prefix = "generic-host",
  default_ports = function() return _G.generic_host_workflow_qa_runtime end,
})
