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

return D
