local contract = require("contract.testing_execution")
local json_encoder = require("testing_runtime.json")
local ports_module = require("testing_runtime.ports")

local A = {}
local runtime_cli = "libraries/testing_runtime/bin/fkst-testing-runtime.js"
local identity_fields = {
  "run_id",
  "trace_id",
  "dedup_key",
  "artifact_kind",
  "attempt_id",
  "fence_version",
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function command_argv(command, intent)
  local argv = {
    "node",
    runtime_cli,
    "artifact-attempt-" .. command,
    "--run-id",
    intent.run_id,
    "--trace-id",
    intent.trace_id,
    "--dedup-key",
    intent.dedup_key,
    "--artifact-kind",
    intent.artifact_kind,
    "--attempt-id",
    intent.attempt_id,
    "--fence-version",
    tostring(intent.fence_version),
  }
  return argv
end

local function run(ports, argv, operation)
  local result = ports.exec_argv(argv, 60)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    local detail = type(result) == "table" and result.stderr or "missing result"
    error("testing-runtime: artifact-attempt-" .. operation .. "-failed: " .. tostring(detail))
  end
  return result.stdout or ""
end

local function validate_bound_completion(intent, completion)
  contract.validate_artifact_attempt_completion(completion)
  for _, field in ipairs(identity_fields) do
    if completion[field] ~= intent[field] then
      error("testing-runtime: artifact-attempt-completion-mismatch: " .. field)
    end
  end
  return completion
end

function A.new(supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  local store = {}

  function store:artifact_pointer(intent)
    contract.validate_artifact_attempt_intent(intent)
    local pointer = trim(run(ports, command_argv("pointer", intent), "pointer"))
    contract.require_artifact_pointer(pointer, "artifact_pointer")
    return pointer
  end

  function store:commit(intent, staged_artifact_root)
    contract.validate_artifact_attempt_intent(intent)
    contract.require_artifact_pointer(staged_artifact_root, "staged_artifact_root")
    local argv = command_argv("commit", intent)
    table.insert(argv, "--staged-root")
    table.insert(argv, staged_artifact_root)
    local completion = ports.decode(run(ports, argv, "commit"))
    validate_bound_completion(intent, completion)
    if completion.artifact_pointer ~= self:artifact_pointer(intent) then
      error("testing-runtime: artifact-attempt-completion-mismatch: artifact_pointer")
    end
    return completion
  end

  function store:lookup(intent)
    contract.validate_artifact_attempt_intent(intent)
    local envelope = ports.decode(run(ports, command_argv("lookup", intent), "lookup"))
    if type(envelope) ~= "table" or type(envelope.found) ~= "boolean" then
      error("testing-runtime: artifact-attempt-lookup-malformed: expected lookup envelope")
    end
    for field, _ in pairs(envelope) do
      if field ~= "found" and field ~= "completion" then
        error("testing-runtime: artifact-attempt-lookup-malformed: unsupported field " .. tostring(field))
      end
    end
    if envelope.found == false then
      if envelope.completion ~= nil then
        error("testing-runtime: artifact-attempt-lookup-malformed: absent lookup returned completion")
      end
      return nil
    end
    if envelope.completion == nil then
      error("testing-runtime: artifact-attempt-lookup-malformed: found lookup omitted completion")
    end
    validate_bound_completion(intent, envelope.completion)
    if envelope.completion.artifact_pointer ~= self:artifact_pointer(intent) then
      error("testing-runtime: artifact-attempt-completion-mismatch: artifact_pointer")
    end
    return envelope.completion
  end

  return store
end

function A.encode_completion(completion)
  contract.validate_artifact_attempt_completion(completion)
  return json_encoder.encode(completion)
end

return A
