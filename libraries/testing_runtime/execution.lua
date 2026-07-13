local contract = require("contract.testing_execution")
local json_codec = require("testing_runtime.json")
local ports_module = require("testing_runtime.ports")
local receipt = require("testing_runtime.receipt")

local X = {}

local runtime_cli = "libraries/testing_runtime/bin/fkst-testing-runtime.js"

local function runtime_paths(root)
  return {
    plan = root .. "/browser-execution-plan.json",
    request = root .. "/browser-execution-request.json",
    receipt = root .. "/browser-execution-receipt.json",
  }
end

local function run_command(ports, argv, timeout, class)
  local result = ports.exec_argv(argv, timeout)
  local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
  if exit_code ~= 0 then
    error(
      "testing-runtime: " .. tostring(class) .. ": exit=" .. tostring(exit_code or -1)
        .. " stderr=" .. tostring(type(result) == "table" and result.stderr or "")
    )
  end
  return result
end

local function copy_without_digest(request)
  local basis = {}
  for key, value in pairs(request or {}) do
    if key ~= "plan_sha256" then basis[key] = value end
  end
  return basis
end

function X.prepare(request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  if type(request) ~= "table" then error("testing-runtime: malformed-request: request must be a table") end
  contract.require_artifact_pointer(request.artifact_root, "artifact_root")
  local paths = runtime_paths(request.artifact_root)
  ports.write(paths.plan, json_codec.encode(copy_without_digest(request)) .. "\n")
  local result = run_command(ports, {
    "node",
    runtime_cli,
    "hash-json",
    "--input",
    paths.plan,
  }, 30, "hash-json-failed")
  local digest = tostring(result.stdout or ""):match("([0-9a-f]+)")
  contract.require_sha256(digest, "plan_sha256")
  request.plan_sha256 = digest
  contract.validate_execution_request(request)
  ports.write(paths.request, json_codec.encode(request) .. "\n")
  return request, paths
end

function X.execute(request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.validate_execution_request(request)
  local paths = runtime_paths(request.artifact_root)
  ports.write(paths.request, json_codec.encode(request) .. "\n")
  run_command(ports, {
    "node",
    runtime_cli,
    "execute",
    "--request",
    paths.request,
    "--receipt",
    paths.receipt,
  }, 120, "browser-execution-failed")
  local decoded = ports.decode(ports.read(paths.receipt))
  receipt.validate(request, decoded)
  return decoded, paths
end

local function substitute_operation_id(argv, operation_id)
  local out = {}
  for _, item in ipairs(argv or {}) do
    table.insert(out, tostring(item):gsub("%${FKST_OPERATION_ID}", operation_id))
  end
  return out
end

function X.fixture_phase(lifecycle, operation_id, phase, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.validate_fixture_lifecycle(lifecycle)
  if type(operation_id) ~= "string" or operation_id == "" then
    error("testing-runtime: fixture-operation-id-missing: operation_id is required")
  end
  local field = tostring(phase) .. "_argv"
  local argv = lifecycle[field]
  if phase == "rollback" and argv == nil then
    return { phase = phase, status = "not-configured", exit_code = 0 }
  end
  if type(argv) ~= "table" then
    error("testing-runtime: fixture-phase-unsupported: " .. tostring(phase))
  end
  local result = ports.exec_argv(substitute_operation_id(argv, operation_id), 120)
  local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
  return {
    phase = phase,
    status = exit_code == 0 and "passed" or "failed",
    exit_code = exit_code or -1,
    stderr = type(result) == "table" and tostring(result.stderr or "") or "",
  }
end

X.runtime_paths = runtime_paths

return X
