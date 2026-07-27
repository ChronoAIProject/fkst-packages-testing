local json_codec = require("testing_runtime.json")

local Store = {}
Store.__index = Store

local sequence = 0

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if handle == nil then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_file(path, body)
  local handle = assert(io.open(path, "wb"))
  handle:write(body)
  handle:close()
end

local function decode(body)
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("generic-host durable store: json.decode is unavailable")
  end
  return json.decode(body)
end

local function bounded(value, label)
  if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") then
    error("generic-host durable store: invalid " .. label)
  end
  return value
end

function Store.new(root, runtime_cli)
  bounded(root, "root")
  if root:sub(1, 1) ~= "/" then error("generic-host durable store: root must be absolute") end
  return setmetatable({ root = root, runtime_cli = bounded(runtime_cli, "runtime CLI") }, Store)
end

function Store:_call(operation, value)
  sequence = sequence + 1
  local request_path = os.tmpname() .. "-generic-host-store-request-" .. tostring(sequence)
  local response_path = os.tmpname() .. "-generic-host-store-response-" .. tostring(sequence)
  value = value or {}
  value.operation = operation
  value.root = self.root
  write_file(request_path, json_codec.encode(value) .. "\n")
  local command = table.concat({
    "node", shell_quote(self.runtime_cli), "--request", shell_quote(request_path),
    "--response", shell_quote(response_path),
  }, " ")
  local ok, _, code = os.execute(command)
  local response_body = read_file(response_path)
  os.remove(request_path)
  os.remove(response_path)
  local response = response_body and decode(response_body) or nil
  if (ok ~= true and ok ~= 0) or type(response) ~= "table" or response.ok ~= true then
    error("generic-host durable store: operation failed: "
      .. tostring(type(response) == "table" and response.error or code or "missing response"), 0)
  end
  return response.result
end

function Store:digest(body)
  return self:_call("digest", { body = body }).digest
end

function Store:read(key)
  local result = self:_call("record-read", { key = key })
  return result.found == true and result.value or nil
end

function Store:list(prefix)
  return self:_call("record-list", { prefix = prefix }).entries or {}
end

function Store:immutable(key, value)
  return self:_call("record-immutable", { key = key, value = value })
end

function Store:cas(key, value, expected_version)
  return self:_call("record-cas", {
    key = key,
    value = value,
    expected_version = expected_version,
  })
end

function Store:claim(key, value)
  return self:_call("record-claim", { key = key, value = value })
end

function Store:complete_replay(key, claim_id, completion)
  return self:_call("replay-complete", {
    key = key,
    claim_id = claim_id,
    completion = completion,
  })
end

function Store:read_artifact(path)
  local result = self:_call("artifact-read", { path = path })
  if result.found ~= true then return nil end
  return { body = result.body, digest = result.digest }
end

function Store:write_artifact(path, body)
  return self:_call("artifact-write", { path = path, body = body })
end

return Store
