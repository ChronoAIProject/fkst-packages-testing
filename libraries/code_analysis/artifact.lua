local analyzer = require("code_analysis.analyzer")
local strings = require("contract.strings")
local execution_contract = require("contract.testing_execution")
local digest = require("testing_runtime.digest")
local canonical_json = require("testing_runtime.json")

local C = {}

C.schema = "testing.code-analysis.v1"
C.reference_schema = "testing.code-analysis-reference.v1"
C.version = 1
C.filename = "code-analysis.v1.json"

local max_string = 512
local max_facts = 512

local artifact_fields = {
  artifact_kind = true,
  artifact_pointer = true,
  fact_count = true,
  facts = true,
  file_count = true,
  schema = true,
  scope = true,
  version = true,
}

local reference_fields = {
  artifact_digest = true,
  artifact_pointer = true,
  artifact_version = true,
  schema = true,
}

local function fail(code, message)
  error("code-analysis: " .. code .. ": " .. message)
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-artifact", context .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-artifact", context .. " has unsupported field " .. tostring(key)) end
  end
end

local function dense_list(value, limit)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest and count <= limit
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or max_string) and value:find("[%z\1-\31]") == nil
end

local function validate_source(value)
  only_fields(value, { column = true, line = true, path = true }, "fact.source")
  if not strings.is_path_safe_key(value.path, max_string) then fail("malformed-artifact", "fact.source.path must be repository-relative") end
  if type(value.line) ~= "number" or value.line < 1 or value.line ~= math.floor(value.line) then fail("malformed-artifact", "fact.source.line must be a positive integer") end
  if type(value.column) ~= "number" or value.column < 1 or value.column ~= math.floor(value.column) then fail("malformed-artifact", "fact.source.column must be a positive integer") end
end

local function validate_artifact_pointer(value, code)
  execution_contract.require_artifact_pointer(value, "code analysis artifact_pointer")
  if value:find("#", 1, true) ~= nil then fail(code, "artifact_pointer must identify a file, not a fragment") end
end

function C.validate_artifact(value)
  only_fields(value, artifact_fields, "artifact")
  if value.schema ~= C.schema or value.version ~= C.version then fail("unsupported-version", "expected " .. C.schema) end
  if value.artifact_kind ~= "code-analysis" then fail("malformed-artifact", "artifact_kind must be code-analysis") end
  validate_artifact_pointer(value.artifact_pointer, "malformed-artifact")
  only_fields(value.scope, { kind = true, repository_root = true }, "scope")
  if value.scope.kind ~= "repository-tree"
    or not strings.is_path_safe_key(value.scope.repository_root, max_string)
    or value.scope.repository_root:sub(-1) == "/" then
    fail("malformed-artifact", "scope must identify a safe repository tree")
  end
  if not dense_list(value.facts, max_facts) then fail("malformed-artifact", "facts must be a bounded dense list") end
  if type(value.fact_count) ~= "number" or value.fact_count ~= #value.facts then fail("malformed-artifact", "fact_count must match facts") end
  if type(value.file_count) ~= "number" or value.file_count < 0 or value.file_count > value.fact_count then fail("malformed-artifact", "file_count is invalid") end
  local files = 0
  for index, fact in ipairs(value.facts) do
    only_fields(fact, { id = true, kind = true, name = true, pointer = true, source = true }, "fact")
    if not bounded(fact.id, 180) or (fact.kind ~= "file" and fact.kind ~= "function") or not bounded(fact.name) then
      fail("malformed-artifact", "fact identity is invalid")
    end
    validate_source(fact.source)
    if fact.pointer ~= value.artifact_pointer .. "#/facts/" .. tostring(index) then fail("malformed-artifact", "fact pointer does not match its canonical position") end
    if fact.kind == "file" then files = files + 1 end
  end
  if files ~= value.file_count then fail("malformed-artifact", "file_count must match file facts") end
  return value
end

function C.validate_reference(value)
  if type(value) ~= "table" then fail("malformed-reference", "reference must be a table") end
  for key, _ in pairs(value) do
    if reference_fields[key] ~= true then fail("malformed-reference", "reference has unsupported field " .. tostring(key)) end
  end
  if value.schema ~= C.reference_schema then fail("malformed-reference", "reference schema is invalid") end
  if value.artifact_version ~= C.version then fail("unsupported-version", "artifact reference version is unsupported") end
  validate_artifact_pointer(value.artifact_pointer, "malformed-reference")
  execution_contract.require_sha256(value.artifact_digest, "code analysis artifact_digest")
  return value
end

function C.copy_reference(value)
  C.validate_reference(value)
  return {
    schema = value.schema,
    artifact_pointer = value.artifact_pointer,
    artifact_digest = value.artifact_digest,
    artifact_version = value.artifact_version,
  }
end

function C.canonical_bytes(value)
  C.validate_artifact(value)
  return canonical_json.encode(value) .. "\n"
end

local function default_write(path, body)
  local directory = path:match("^(.*)/[^/]+$")
  if directory == nil or not strings.is_artifact_root(directory) then return nil, "unsafe artifact directory" end
  local quoted = "'" .. directory:gsub("'", "'\\''") .. "'"
  local ok = os.execute("mkdir -p " .. quoted)
  if ok ~= true and ok ~= 0 then return nil, "could not create artifact directory" end
  local handle, err = io.open(path, "wb")
  if handle == nil then return nil, err end
  local wrote, write_err = handle:write(body)
  handle:close()
  return wrote and true or nil, write_err
end

local function default_read(path)
  local handle, err = io.open(path, "rb")
  if handle == nil then error(err or "artifact is missing") end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function decode(body, ports)
  if type(ports) == "table" and type(ports.decode) == "function" then return ports.decode(body) end
  if type(json) == "table" and type(json.decode) == "function" then return json.decode(body) end
  fail("decoder-unavailable", "json.decode is required")
end

local function sha256_file(path, ports)
  local value
  if type(ports) == "table" and type(ports.sha256_file) == "function" then
    value = ports.sha256_file(path)
  else
    value = digest.sha256_file(path, ports)
  end
  execution_contract.require_sha256(value, "code analysis artifact_digest")
  return value
end

function C.persist(repository_root, artifact_pointer, ports)
  validate_artifact_pointer(artifact_pointer, "malformed-reference")
  local artifact = analyzer.analyze(repository_root, artifact_pointer, ports)
  local body = C.canonical_bytes(artifact)
  local write = type(ports) == "table" and ports.write or default_write
  local ok, err = write(artifact_pointer, body)
  if not ok then fail("artifact-write-failed", tostring(err or "write failed")) end
  local artifact_digest = sha256_file(artifact_pointer, ports)
  local reference = {
    schema = C.reference_schema,
    artifact_pointer = artifact_pointer,
    artifact_digest = artifact_digest,
    artifact_version = C.version,
  }
  C.validate_reference(reference)
  return reference, artifact, body
end

function C.load_verified(reference, ports)
  reference = C.copy_reference(reference)
  local read = type(ports) == "table" and ports.read or default_read
  local ok, body = pcall(read, reference.artifact_pointer)
  if not ok or type(body) ~= "string" or body == "" then fail("artifact-missing", "persisted artifact could not be read") end
  local actual = sha256_file(reference.artifact_pointer, ports)
  if actual ~= reference.artifact_digest then fail("digest-mismatch", "persisted artifact does not match the expected digest") end
  local decoded_ok, artifact = pcall(decode, body, ports)
  if not decoded_ok then fail("malformed-artifact", "persisted artifact is not valid JSON") end
  C.validate_artifact(artifact)
  if artifact.artifact_pointer ~= reference.artifact_pointer or artifact.version ~= reference.artifact_version then
    fail("artifact-mismatch", "persisted artifact identity does not match its reference")
  end
  return artifact, body, reference
end

return C
