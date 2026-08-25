local runtime_client = require("testing_runtime.runtime_client")

local M = {}
local max_hash_bytes = 1024 * 1024

local function run_root(path)
  return type(path) == "string" and path:match("^(.testing/runs/[^/]+)") or nil
end

local function client(options)
  return runtime_client.new({
    cli_global = "qa_publication_runtime_cli",
    cli_env = "FKST_QA_PUBLICATION_RUNTIME_CLI",
    config_global = "qa_publication_runtime_config_ref",
    config_env = "FKST_QA_PUBLICATION_RUNTIME_CONFIG_REF",
    error_prefix = "testing-runtime: qa-publication",
    scratch_root = ".testing/runtime/qa-publication/runtime-io",
  }, options)
end

function M.configured(options) return client(options).configured() end

function M.production(options)
  local cli = client(options)
  return {
    sha256_bytes = function(bytes, artifact_root)
      local root = run_root(artifact_root)
      if type(bytes) ~= "string" or #bytes > max_hash_bytes then
        error("testing-runtime: qa-publication-sha256-bytes-invalid: bytes must be bounded")
      end
      if root == nil then
        error("testing-runtime: qa-publication-run-root-missing: artifact root must identify a run")
      end
      local result = cli.call("sha256-bytes", { bytes = bytes }, root, artifact_root, 15)
      if type(result) ~= "table" or type(result.sha256) ~= "string"
        or result.sha256:match("^[0-9a-f]+$") == nil or #result.sha256 ~= 64 then
        error("testing-runtime: qa-publication-sha256-bytes-result-invalid: runtime returned an invalid digest")
      end
      return result.sha256
    end,
    load_ledger = function(path) return cli.call("publication-load-ledger", { path = path }, run_root(path), path, 15) end,
    save_ledger = function(path, value, expected)
      local result = cli.call("publication-save-ledger", {
        path = path, value = value, expected_version = expected,
      }, run_root(path), path, 15)
      return type(result) == "table" and result.saved == true
    end,
    publish_artifact = function(request)
      return cli.call("publication-publish-artifact", request, run_root(request.artifact_ref), request.run_id, 15)
    end,
    write_artifact = function(path, value)
      local result = cli.call("artifact-write", { path = path, value = value }, run_root(path), path, 15)
      return type(result) == "table" and result.written == true
    end,
    write_report = function(path, value)
      return cli.call("publication-write-report", { path = path, value = value }, run_root(path), path, 15)
    end,
    load_artifact = function(path)
      return cli.call("artifact-load", { path = path }, run_root(path), path, 15)
    end,
  }
end

return M
