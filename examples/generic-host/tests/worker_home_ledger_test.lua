local t = fkst.test

return {
  test_generic_host_worker_home_ledger = function()
    local candidates = {
      "examples/generic-host/tests/worker_home_ledger_test.js",
      "packages/generic-host/tests/worker_home_ledger_test.js",
    }
    local script
    for _, candidate in ipairs(candidates) do
      local handle = io.open(candidate, "rb")
      if handle then handle:close(); script = candidate; break end
    end
    t.is_true(script ~= nil)
    local ok, why, code = os.execute("node " .. script)
    t.is_true(ok == true or code == 0, tostring(why) .. ":" .. tostring(code))
  end,
}
