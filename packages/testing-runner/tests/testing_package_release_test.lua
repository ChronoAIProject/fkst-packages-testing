local release = require("contract.testing_package_release")
local t = fkst.test

local function plain(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = plain(item) end
  return result
end

local function load(name)
  local path = "packages/testing-runner/tests/fixtures/testing-package-release.v1/" .. name .. ".json"
  local handle = assert(io.open(path, "rb"))
  local value = json.decode(handle:read("*a"))
  handle:close()
  return value
end

return {
  test_valid_release_contract = function()
    local value = load("valid")
    t.eq(release.validate(value), value)
    t.eq(release.canonicalize(plain(value)):sub(-1), "\n")
  end,

  test_release_contract_rejects_unknown_fields = function()
    local ok = pcall(function() release.validate(load("invalid-unknown-field")) end)
    t.eq(ok, false)
  end,
}
