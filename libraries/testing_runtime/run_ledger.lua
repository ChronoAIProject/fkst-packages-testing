local artifact_attempt = require("testing_runtime.artifact_attempt")
local json_encoder = require("testing_runtime.json")
local ports_module = require("testing_runtime.ports")

local L = {}
local runtime_cli = "libraries/testing_runtime/bin/fkst-testing-runtime.js"
local identity_schema = "testing-runner.run-identity.v1"
local record_schema = "testing-runner.run-ledger-record.v1"
local runner_statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
}

local function bounded(value, limit)
  return type(value) == "string"
    and value ~= ""
    and #value <= limit
    and value:find("[%z\1-\31\127]") == nil
end

local function exact_fields(value, allowed, context)
  if type(value) ~= "table" then error("testing-runtime: " .. context .. " must be a table") end
  for field, _ in pairs(value) do
    if allowed[field] ~= true then error("testing-runtime: " .. context .. " has unsupported field " .. tostring(field)) end
  end
  for field, _ in pairs(allowed) do
    if value[field] == nil then error("testing-runtime: " .. context .. " is missing " .. field) end
  end
end

local function validate_identity(identity)
  exact_fields(identity, { schema = true, job = true, trace_id = true, dedup_key = true }, "run-ledger-identity")
  if identity.schema ~= identity_schema then error("testing-runtime: run-ledger-identity schema is invalid") end
  if not bounded(identity.job, 120) or identity.job:match("^[%w._-]+$") == nil then error("testing-runtime: run-ledger-identity job is invalid") end
  if not bounded(identity.trace_id, 180) then error("testing-runtime: run-ledger-identity trace_id is invalid") end
  if not bounded(identity.dedup_key, 180) then error("testing-runtime: run-ledger-identity dedup_key is invalid") end
  return identity
end

local function command_argv(command, identity)
  validate_identity(identity)
  return { "node", runtime_cli, "run-ledger-" .. command, "--job", identity.job, "--trace-id", identity.trace_id, "--dedup-key", identity.dedup_key }
end

local function run(ports, argv, operation)
  local result = ports.exec_argv(argv, 60)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then error("testing-runtime: run-ledger-" .. operation .. "-failed: " .. tostring(type(result) == "table" and result.stderr or "missing result")) end
  return ports.decode(result.stdout or "")
end

local function completion_identity(completion)
  return {
    schema = "test-artifacts.attempt-commit-intent.v1",
    run_id = completion.run_id,
    trace_id = completion.trace_id,
    dedup_key = completion.dedup_key,
    artifact_kind = completion.artifact_kind,
    attempt_id = completion.attempt_id,
    fence_version = completion.fence_version,
  }
end

local function same_completion(left, right)
  for _, field in ipairs({
    "schema",
    "run_id",
    "trace_id",
    "dedup_key",
    "artifact_kind",
    "attempt_id",
    "fence_version",
    "manifest_sha256",
    "artifact_pointer",
  }) do
    if left[field] ~= right[field] then return false end
  end
  return true
end

local function validate_terminal_result(result, identity, completion)
  if type(result) ~= "table" or result.schema ~= "testing-runner.result.v1" then error("testing-runtime: run-ledger terminal result schema is invalid") end
  if result.job ~= identity.job then error("testing-runtime: run-ledger terminal result job mismatch") end
  if runner_statuses[result.status] ~= true then error("testing-runtime: run-ledger terminal result status is invalid") end
  if result.trace_id ~= identity.trace_id then error("testing-runtime: run-ledger terminal result trace_id mismatch") end
  if result.dedup_key ~= identity.dedup_key then error("testing-runtime: run-ledger terminal result dedup_key mismatch") end
  if result.artifact_root ~= completion.artifact_pointer then error("testing-runtime: run-ledger terminal result artifact_root mismatch") end
  json_encoder.encode(result)
  return result
end

local function validate_record(record, identity, attempt_store)
  local allowed = {
    schema = true,
    state = true,
    job = true,
    trace_id = true,
    dedup_key = true,
    fence_version = true,
  }
  if type(record) == "table" and record.state == "completed" then
    allowed.terminal_attempt = true
    allowed.terminal_result = true
  end
  exact_fields(record, allowed, "run-ledger-record")
  if record.schema ~= record_schema then error("testing-runtime: run-ledger-record schema is invalid") end
  if record.job ~= identity.job or record.trace_id ~= identity.trace_id or record.dedup_key ~= identity.dedup_key then error("testing-runtime: run-ledger-record identity mismatch") end
  if type(record.fence_version) ~= "number" or record.fence_version < 1 or math.floor(record.fence_version) ~= record.fence_version then error("testing-runtime: run-ledger-record fence_version is invalid") end
  if record.state ~= "acquired" and record.state ~= "completed" then error("testing-runtime: run-ledger-record state is invalid") end
  if record.state == "completed" then
    local verified = attempt_store:lookup(completion_identity(record.terminal_attempt))
    if verified == nil or not same_completion(verified, record.terminal_attempt) then error("testing-runtime: run-ledger terminal attempt is not verified") end
    validate_terminal_result(record.terminal_result, identity, verified)
  end
  return record
end

function L.new(supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  local attempt_store = artifact_attempt.new(ports)
  local store = {}

  function store:lookup(identity)
    local envelope = run(ports, command_argv("lookup", identity), "lookup")
    if type(envelope) ~= "table" or type(envelope.found) ~= "boolean" then error("testing-runtime: run-ledger-lookup-malformed: expected lookup envelope") end
    if envelope.found == false then
      if envelope.record ~= nil then error("testing-runtime: run-ledger-lookup-malformed: absent lookup returned record") end
      return nil
    end
    if envelope.record == nil then error("testing-runtime: run-ledger-lookup-malformed: found lookup omitted record") end
    return validate_record(envelope.record, identity, attempt_store)
  end

  function store:acquire(identity)
    local envelope = run(ports, command_argv("acquire", identity), "acquire")
    if type(envelope) ~= "table" or type(envelope.created) ~= "boolean" or envelope.record == nil then error("testing-runtime: run-ledger-acquire-malformed: expected acquisition envelope") end
    return validate_record(envelope.record, identity, attempt_store), envelope.created
  end

  function store:complete(identity, fence_version, terminal_attempt, terminal_result)
    local argv = command_argv("complete", identity)
    table.insert(argv, "--fence-version")
    table.insert(argv, tostring(fence_version))
    table.insert(argv, "--terminal-attempt")
    table.insert(argv, json_encoder.encode(terminal_attempt))
    table.insert(argv, "--terminal-result")
    table.insert(argv, json_encoder.encode(terminal_result))
    local record = run(ports, argv, "complete")
    return validate_record(record, identity, attempt_store)
  end

  return store
end

L.identity_schema = identity_schema
L.record_schema = record_schema

return L
