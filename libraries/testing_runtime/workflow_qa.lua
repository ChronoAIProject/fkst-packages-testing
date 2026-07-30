local runtime_client = require("testing_runtime.runtime_client")

local M = {}

local function run_root(path)
  return type(path) == "string" and path:match("^(.testing/runs/[^/]+)") or nil
end

local function client(options)
  return runtime_client.new({
    cli_global = "workflow_qa_runtime_cli",
    cli_env = "FKST_WORKFLOW_QA_RUNTIME_CLI",
    config_global = "workflow_qa_runtime_config_ref",
    config_env = "FKST_WORKFLOW_QA_RUNTIME_CONFIG_REF",
    error_prefix = "testing-runtime: workflow-qa",
    scratch_root = ".testing/runtime/workflow-qa/runtime-io",
  }, options)
end

function M.configured(options) return client(options).configured() end

function M.production(options)
  local cli = client(options)
  return {
    load_state = function(path) return cli.call("workflow-load-state", { path = path }, run_root(path), path, 15) end,
    load_run = function(trace_id, dedup_key)
      return cli.call("workflow-load-run", { trace_id = trace_id, dedup_key = dedup_key }, nil, dedup_key, 15)
    end,
    load_run_by_id = function(run_id)
      return cli.call("workflow-load-run-by-id", { run_id = run_id }, nil, run_id, 15)
    end,
    list_pending_runs = function(limit)
      return cli.call("workflow-list-pending-runs", { limit = limit }, nil, "pending", 15)
    end,
    save_state = function(path, value, expected)
      local result = cli.call("workflow-save-state", {
        path = path, value = value, expected_version = expected,
      }, run_root(path), path, 15)
      return type(result) == "table" and result.saved == true
    end,
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
  }
end

return M
