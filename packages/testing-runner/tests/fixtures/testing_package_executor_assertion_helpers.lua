local runtime_json = require("testing_runtime.json")
local t = fkst.test

local M = {}

function M.expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  if fragment ~= nil then t.is_true(tostring(err):find(fragment, 1, true) ~= nil) end
end

function M.assert_zero_execution_effects(value)
  t.eq(value.calls.now, 0)
  t.eq(#value.calls.completed_queries, 0)
  t.eq(#value.calls.claims, 0)
  t.eq(#value.calls.freshness, 0)
  t.eq(#value.calls.intents, 0)
  t.eq(#value.calls.receipts, 0)
  t.eq(#value.calls.completions, 0)
  t.eq(#value.calls.browser, 0)
  t.eq(#value.calls.writes, 0)
end

function M.assert_semantics(actual, expected)
  t.eq(runtime_json.encode(actual), runtime_json.encode(expected))
end

return M
