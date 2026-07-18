local t = fkst.test

return {
  test_node_runtime_regressions = function()
    local ok, _, code = os.execute("node packages/environment-factory/tests/node_runtime_test.js")
    t.is_true(ok == true or ok == 0, "node runtime regressions failed exit=" .. tostring(code))
  end,
}
