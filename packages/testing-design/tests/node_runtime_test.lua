local t = fkst.test

return {
  test_node_runtime_analysis_and_replay = function()
    local ok, _, code = os.execute("node packages/testing-design/tests/node_runtime_test.js")
    t.is_true(ok == true or ok == 0, "testing-design node runtime failed exit=" .. tostring(code))
  end,
}
