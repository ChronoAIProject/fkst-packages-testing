local M = {}

local function append(argv, value)
  table.insert(argv, tostring(value))
end

local function append_flag(argv, flag, value)
  if value ~= nil and value ~= "" then
    append(argv, flag)
    append(argv, value)
  end
end

local function append_platform_modules(argv, payload, dense_list)
  if dense_list(payload.modules or {}) then
    for _, module in ipairs(payload.modules) do
      append_flag(argv, "--module", module)
    end
  elseif payload.module ~= nil then
    append_flag(argv, "--module", payload.module)
  end
end

local function append_priorities(argv, priorities, dense_list)
  if dense_list(priorities or {}) then
    for _, priority in ipairs(priorities) do
      append_flag(argv, "--priority", priority)
    end
  end
end

function M.argv(job, payload, spec, dense_list)
  local argv = {
    payload.python or "python3",
    "-m",
    "agentic_testing.cli",
    "--root",
    payload.agentic_testing_repo_root or ".",
    "--config",
    payload.config or "config/current-online-regression.yaml",
    spec.subcommand,
    "--once",
  }
  if payload.dry_run_github ~= false then append(argv, "--dry-run-github") end
  if payload.no_browser == true then append(argv, "--no-browser") end

  if job == "module" then
    append_flag(argv, "--module", payload.module)
    append_flag(argv, "--e2e-driver", payload.e2e_driver)
  elseif job == "platform" then
    append_platform_modules(argv, payload, dense_list)
    append_flag(argv, "--e2e-driver", payload.e2e_driver)
    append_priorities(argv, payload.priority, dense_list)
  elseif job == "online_regression" then
    append_flag(argv, "--driver", payload.driver)
    if payload.final_summary == true then append(argv, "--final-summary") end
  end
  return argv
end

function M.command(job, payload, spec, dense_list, quote)
  local quoted = {}
  for _, value in ipairs(M.argv(job, payload, spec, dense_list)) do
    table.insert(quoted, quote(value))
  end
  return table.concat(quoted, " ")
end

function M.adapter(job, payload, context)
  return {
    name = "agentic-testing-cli",
    command = M.command(job, payload, context.spec, context.dense_list, context.quote),
  }
end

function M.run(job, payload, context, exec)
  if payload.dry_run ~= false then
    return context.result_payload("planned", { adapter = M.adapter(job, payload, context) })
  end
  local run = exec or exec_sync
  if type(run) ~= "function" then
    error("testing-runner: exec-unavailable: exec_sync is required when dry_run=false")
  end
  local root = payload.agentic_testing_repo_root or "."
  local out = run("cd " .. context.quote(root) .. " && " .. M.command(job, payload, context.spec, context.dense_list, context.quote))
  local code = type(out) == "table" and tonumber(out.exit_code) or nil
  local status = code == 0 and "passed" or "failed"
  return context.result_payload(status, {
    adapter = M.adapter(job, payload, context),
    exit_code = code or -1,
    stderr = type(out) == "table" and out.stderr or "",
  })
end

return M
