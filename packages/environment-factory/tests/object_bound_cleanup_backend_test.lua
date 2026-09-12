local t = fkst.test

return {
  test_object_bound_cleanup_backend_selection = function()
    local candidates = {
      "packages/environment-factory/tests/object_bound_cleanup_backend_test.py",
      "tests/object_bound_cleanup_backend_test.py",
    }
    local script
    for _, candidate in ipairs(candidates) do
      local handle = io.open(candidate, "rb")
      if handle then handle:close(); script = candidate; break end
    end
    t.is_true(script ~= nil)
    local ok, why, code = os.execute("/usr/bin/python3 -I " .. script)
    t.is_true(ok == true or code == 0, tostring(why) .. ":" .. tostring(code))
  end,
}
