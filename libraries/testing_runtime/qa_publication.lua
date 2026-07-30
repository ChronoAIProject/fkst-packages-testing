local runtime_client = require("testing_runtime.runtime_client")

local M = {}

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
