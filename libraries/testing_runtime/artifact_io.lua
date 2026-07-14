local A = {}

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function production_read(path)
  local handle = io.open(path, "r")
  if handle == nil then return nil end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function production_write(path, content)
  local directory = assert(path:match("^(.*)/[^/]+$"), "testing-runtime: artifact path requires a directory")
  local created = os.execute("mkdir -p " .. shell_quote(directory))
  assert(created == true or created == 0, "testing-runtime: failed to create artifact directory")
  local handle = assert(io.open(path, "w"))
  assert(handle:write(content))
  handle:close()
  return true
end

function A.resolve(ports)
  ports = ports or {}
  return {
    read = ports.read or production_read,
    write = ports.write or production_write,
  }
end

function A.read(path, ports)
  return A.resolve(ports).read(path)
end

function A.write_immutable(path, content, ports)
  local resolved = A.resolve(ports)
  local existing = resolved.read(path)
  if existing == nil then
    resolved.write(path, content)
    return true
  end
  if existing ~= content then
    error("testing-runtime: immutable-artifact-conflict: " .. tostring(path))
  end
  return false
end

return A
