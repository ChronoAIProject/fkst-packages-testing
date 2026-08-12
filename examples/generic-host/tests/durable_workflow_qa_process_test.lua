local process = require("test_support.durable_workflow_qa_process")
local t = fkst.test

local function write_file(path, body)
  local handle = assert(io.open(path, "wb"))
  handle:write(body)
  handle:close()
end

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
  test_child_log_count_scopes_each_log_once = function()
    local root = os.tmpname() .. "-framework-child"
    os.remove(root)
    assert(os.execute("mkdir -p '" .. root .. "'"))
    write_file(root .. "/adapter.intake-1.log", "MARKER\nMARKER\n")
    write_file(root .. "/adapter.intake-2.log", "MARKER\n")
    write_file(root .. "/adapter.terminal-1.log", "MARKER\n")
    t.eq(process.count_child_logs(root, "adapter.intake-", "MARKER"), 2)
    t.eq(process.count_child_logs(root, "adapter.intake-", "ABSENT"), 0)
    assert(os.execute("rm -rf '" .. root .. "'"))
  end,

  test_real_supervisor_package_roots_match_generic_host_closed_world_roots = function()
    local expected = normalized_closed_world_roots()
    local actual = process.package_names()
    t.eq(#actual, #expected)
    for index, name in ipairs(expected) do t.eq(actual[index], name) end
    t.eq(actual[2], "local-qa-host-adapter")
  end,
}
