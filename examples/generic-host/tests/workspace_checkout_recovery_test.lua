local t = fkst.test

return {
  test_workspace_checkout_recovery = function()
    local candidates = {
      "examples/generic-host/tests/workspace_checkout_recovery_test.js",
      "packages/generic-host/tests/workspace_checkout_recovery_test.js",
    }
    local command
    for _, candidate in ipairs(candidates) do
      local file = io.open(candidate, "r")
      if file then file:close(); command = candidate; break end
    end
    if command == nil then error("generic-host workspace recovery test script is unavailable") end
    local ok, _, code = os.execute("node " .. command)
    t.is_true(ok == true or code == 0)
  end,
}
