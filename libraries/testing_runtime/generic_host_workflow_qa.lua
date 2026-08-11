local runtime_client = require("testing_runtime.runtime_client")

local M = {}

local function run_root(path)
  return type(path) == "string" and path:match("^(.testing/runs/[^/]+)") or nil
end

local function client(options)
  return runtime_client.new({
    cli_global = "generic_host_workflow_qa_runtime_cli",
    cli_env = "FKST_WORKFLOW_QA_ADAPTER_RUNTIME_CLI",
    config_global = "generic_host_workflow_qa_runtime_config_ref",
    config_env = "FKST_WORKFLOW_QA_ADAPTER_RUNTIME_CONFIG_REF",
    error_prefix = "testing-runtime: generic-host-workflow-qa",
    scratch_root = ".testing/runtime/generic-host-workflow-qa/runtime-io",
  }, options)
end

function M.configured(options) return client(options).configured() end

function M.production(options)
  local cli = client(options)
  return {
    load_artifact = function(path)
      return cli.call("artifact-load", { path = path }, run_root(path), path, 15)
    end,
    write_artifact = function(path, value)
      local result = cli.call("artifact-write", { path = path, value = value }, run_root(path), path, 15)
      return type(result) == "table" and result.written == true
    end,
    artifact_digest = function(path)
      local result = cli.call("artifact-digest", { path = path }, run_root(path), path, 15)
      return type(result) == "table" and result.digest or nil
    end,
    claim_qa_run_intake = function(value)
      return cli.call("host-claim-qa-run-intake", value, nil, value.run_id, 15)
    end,
    claim_preauthorization = function(value)
      return cli.call("host-claim-preauthorization", value, nil, value.dedup_key, 15)
    end,
    grant_values = function(request, materials)
      return cli.call("host-grant-values", { request = request, materials = materials }, nil,
        request.dedup_key, 15)
    end,
    record_terminal = function(value)
      local result = cli.call("host-record-terminal", value, nil, value.run_id, 15)
      return type(result) == "table" and result.recorded == true
    end,
  }
end

return M
