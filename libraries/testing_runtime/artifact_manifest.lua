local contract = require("contract.testing_execution")
local ports_module = require("testing_runtime.ports")

local M = {}
local runtime_cli = "libraries/testing_runtime/bin/fkst-testing-runtime.js"

function M.build(artifact_root, paths, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.require_artifact_pointer(artifact_root, "artifact_root")
  if type(paths) ~= "table" then error("testing-runtime: manifest-paths-invalid: paths must be a table") end
  local argv = {
    "node",
    runtime_cli,
    "manifest",
    "--root",
    artifact_root,
    "--out",
    artifact_root .. "/artifact-manifest.json",
  }
  for _, path in ipairs(paths) do
    contract.require_artifact_pointer(path, "manifest path")
    table.insert(argv, "--path")
    table.insert(argv, path)
  end
  local result = ports.exec_argv(argv, 60)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: artifact-manifest-failed: " .. tostring(type(result) == "table" and result.stderr or "missing result"))
  end
  local manifest = ports.decode(ports.read(artifact_root .. "/artifact-manifest.json"))
  contract.validate_artifact_manifest(manifest)
  return manifest
end

function M.build_staged(staged_root, artifact_root, relative_paths, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.require_artifact_pointer(staged_root, "staged_root")
  contract.require_artifact_pointer(artifact_root, "artifact_root")
  if type(relative_paths) ~= "table" then
    error("testing-runtime: manifest-paths-invalid: relative_paths must be a table")
  end
  local argv = {
    "node",
    runtime_cli,
    "manifest",
    "--root",
    artifact_root,
    "--out",
    staged_root .. "/artifact-manifest.json",
    "--source-root", staged_root,
  }
  for _, relative in ipairs(relative_paths) do
    local logical_path = artifact_root .. "/" .. tostring(relative or "")
    contract.require_artifact_pointer(logical_path, "manifest path")
    table.insert(argv, "--path")
    table.insert(argv, logical_path)
  end
  local result = ports.exec_argv(argv, 60)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: staged-artifact-manifest-failed: " .. tostring(result and result.stderr or "missing result"))
  end
  local manifest = ports.decode(ports.read(staged_root .. "/artifact-manifest.json"))
  return contract.validate_artifact_manifest(manifest)
end

function M.digest(path, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.require_artifact_pointer(path, "artifact_manifest_path")
  local result = ports.exec_argv({ "node", runtime_cli, "hash-file", "--input", path }, 60)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: artifact-manifest-digest-failed: " .. tostring(result and result.stderr or "missing result"))
  end
  local digest = tostring(result.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return contract.require_sha256(digest, "manifest_sha256")
end

function M.read(path, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.require_artifact_pointer(path, "artifact_manifest_path")
  local manifest = ports.decode(ports.read(path))
  return contract.validate_artifact_manifest(manifest)
end

return M
