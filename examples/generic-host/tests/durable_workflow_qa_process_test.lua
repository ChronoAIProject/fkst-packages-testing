local process = require("test_support.durable_workflow_qa_process")
local t = fkst.test

local function normalized_closed_world_roots()
  local configured = os.getenv("FKST_GENERIC_HOST_CLOSED_WORLD_ROOTS")
  if type(configured) ~= "string" or configured == "" then
    error("generic-host process composition test: closed-world roots are unavailable")
  end
  local names = { "generic-host" }
  for root in configured:gmatch("%S+") do
    local normalized_root = root:gsub("^@platform/", "")
    table.insert(names, normalized_root)
  end
  return names
end

return {
  test_real_supervisor_package_roots_match_generic_host_closed_world_roots = function()
    local expected = normalized_closed_world_roots()
    local actual = process.package_names()
    t.eq(#actual, #expected)
    for index, name in ipairs(expected) do t.eq(actual[index], name) end
    t.eq(actual[2], "local-qa-host-adapter")
  end,
}
