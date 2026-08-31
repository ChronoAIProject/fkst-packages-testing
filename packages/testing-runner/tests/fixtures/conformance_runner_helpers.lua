local M = {}
function M.index(root) return M._read(root .. "/index.json") end
function M._read(path) local handle = assert(io.open(path, "rb")); local body = handle:read("*a"); handle:close(); return json.decode(body) end
function M.fixture(root, name)
  return M._read(root .. "/" .. name .. ".json")
end
function M.each(root, names, callback)
  for _, name in ipairs(names) do callback(name, M.fixture(root, name)) end
end
function M.assert_expected(t, value, expected)
  t.eq(value.case, expected); t.eq(value.portable_valid, true)
end
return M
