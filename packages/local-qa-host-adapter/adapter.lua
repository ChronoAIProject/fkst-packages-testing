local host_adapter = require("testing_runtime.workflow_qa_host_adapter")

return host_adapter.new({
  error_prefix = "local-qa-host",
  default_ports = function()
    return _G.local_qa_workflow_qa_runtime
  end,
})
