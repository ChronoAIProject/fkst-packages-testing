local contract = require("contract.testing_execution")
local ports_module = require("testing_runtime.ports")

local D = {}
local runtime_cli = "libraries/testing_runtime/bin/fkst-testing-runtime.js"

local function executor(supplied_ports)
  if type(supplied_ports) == "table" and type(supplied_ports.exec_argv) == "function" then
    return supplied_ports.exec_argv
  end
  return ports_module.production().exec_argv
end

function D.sha256_file(path, supplied_ports)
  contract.require_artifact_pointer(path, "digest path")
  local result = executor(supplied_ports)({ "node", runtime_cli, "hash-file", "--input", path }, 30)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: digest-failed: " .. tostring(type(result) == "table" and result.stderr or "missing result"))
  end
  local digest = tostring(result.stdout or ""):match("^([0-9a-f]+)%s*$")
  contract.require_sha256(digest, "artifact digest")
  return digest
end

function D.read_sha256_file(path, supplied_ports)
  contract.require_artifact_pointer(path, "digest path")
  local result = executor(supplied_ports)({ "node", runtime_cli, "read-hashed-file", "--input", path }, 30)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: digest-failed: " .. tostring(type(result) == "table" and result.stderr or "missing result"))
  end
  local output = tostring(result.stdout or "")
  local digest = output:sub(1, 64)
  if output:sub(65, 65) ~= "\n" then error("testing-runtime: digest-failed: malformed read-hashed-file output") end
  contract.require_sha256(digest, "artifact digest")
  return output:sub(66), digest
end

return D
