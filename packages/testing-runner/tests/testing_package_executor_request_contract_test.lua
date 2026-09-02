local contract = require("contract.testing_package_executor")
local request_fixtures = require("tests.fixtures.testing_package_executor_request_helpers")
local t = fkst.test

return {
  test_shared_request_schema_fixtures_match_runtime_validation = function()
    for _, name in ipairs(request_fixtures.names) do
      local shared = request_fixtures.load(name)
      t.eq(shared.case, name)
      t.eq(type(shared.portable_valid), "boolean")
      t.eq(type(shared.runtime_valid), "boolean")
      t.eq(type(shared.resolver_error), "string")
      t.eq(type(shared.request), "table")

      local ok, result = pcall(function()
        return contract.validate_request(shared.request)
      end)
      t.eq(ok, shared.runtime_valid)
      if ok then t.eq(result, shared.request) end
    end
  end,
}
