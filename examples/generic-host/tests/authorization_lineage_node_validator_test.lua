local process = require("test_support.durable_workflow_qa_process")
local t = fkst.test

return {
  test_node_authorization_lineage_validator_matches_fail_closed_contract = function()
    local candidates = {
      "examples/generic-host/tests/authorization_lineage_node_validator_test.js",
      "packages/generic-host/tests/authorization_lineage_node_validator_test.js",
    }
    local script
    for _, candidate in ipairs(candidates) do
      if process.read_file(candidate) ~= nil then script = candidate break end
    end
    t.is_true(type(script) == "string")
    local result = process.exec({ "node", script })
    t.eq(result.exit_code, 0)
  end,
}
