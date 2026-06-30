local M = {}

local max_string = 512
local max_path = 4096
local max_excerpt = 600

local jobs = {
  module = {
    request_schema = "testing-runner.module-test-loop.request.v1",
    subcommand = "module-test-loop",
    output_job = "module-test-loop",
  },
  platform = {
    request_schema = "testing-runner.platform-test-loop.request.v1",
    subcommand = "platform-test-loop",
    output_job = "platform-test-loop",
  },
  online_regression = {
    request_schema = "testing-runner.online-regression.request.v1",
    subcommand = "online-regression-heartbeat",
    output_job = "online-regression",
  },
}

local function bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= limit
end
M.bounded_string = bounded_string

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
M.shell_single_quote = quote

local function append(argv, value)
  table.insert(argv, tostring(value))
end

local function append_flag(argv, flag, value)
  if value ~= nil and value ~= "" then
    append(argv, flag)
    append(argv, value)
  end
end

local function dense_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      return false
    end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
end
M.dense_list = dense_list

local function safe_key(value)
  local text = tostring(value or "planned")
  text = text:gsub("[^%w%._%-%/#]", "-")
  text = text:gsub("^/+", "")
  if text == "" then text = "planned" end
  if #text > 180 then text = text:sub(1, 180) end
  return text
end
M.safe_key = safe_key

local function spec_for(job)
  local spec = jobs[job]
  if spec == nil then
    error("testing-runner: unknown-job: " .. tostring(job))
  end
  return spec
end
M.spec_for = spec_for

function M.validate_request(job, payload)
  local spec = spec_for(job)
  if type(payload) ~= "table" then
    error("testing-runner: malformed-request: payload must be a table")
  end
  if payload.schema ~= spec.request_schema then
    error("testing-runner: unknown-schema: expected " .. spec.request_schema)
  end
  if job == "module" and not bounded_string(payload.module, max_string) then
    error("testing-runner: malformed-request: module is required")
  end
  if job == "platform" and payload.modules ~= nil and not dense_list(payload.modules) then
    error("testing-runner: malformed-request: modules must be a dense list")
  end
  if payload.artifact_root ~= nil and not bounded_string(payload.artifact_root, max_path) then
    error("testing-runner: malformed-request: artifact_root is too large")
  end
  return payload
end

function M.artifact_root(job, payload)
  if bounded_string(payload.artifact_root, max_path) then
    return payload.artifact_root
  end
  return ".testing/runs/" .. safe_key(payload.run_id or payload.dedup_key or payload.module or job)
end

local function append_platform_modules(argv, payload)
  if dense_list(payload.modules or {}) then
    for _, module in ipairs(payload.modules) do
      append_flag(argv, "--module", module)
    end
  elseif payload.module ~= nil then
    append_flag(argv, "--module", payload.module)
  end
end

local function append_priorities(argv, priorities)
  if dense_list(priorities or {}) then
    for _, priority in ipairs(priorities) do
      append_flag(argv, "--priority", priority)
    end
  end
end

function M.argv(job, payload)
  M.validate_request(job, payload)
  local spec = spec_for(job)
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
    append_platform_modules(argv, payload)
    append_flag(argv, "--e2e-driver", payload.e2e_driver)
    append_priorities(argv, payload.priority)
  elseif job == "online_regression" then
    append_flag(argv, "--driver", payload.driver)
    if payload.final_summary == true then append(argv, "--final-summary") end
  end
  return argv
end

function M.command(job, payload)
  local quoted = {}
  for _, value in ipairs(M.argv(job, payload)) do
    table.insert(quoted, quote(value))
  end
  return table.concat(quoted, " ")
end

local function excerpt(value)
  local text = tostring(value or "")
  if #text > max_excerpt then
    return text:sub(1, max_excerpt)
  end
  return text
end

local function source_ref(payload)
  if type(payload.source_ref) == "table" then
    return { kind = tostring(payload.source_ref.kind or "request"), ref = tostring(payload.source_ref.ref or "unknown") }
  end
  return { kind = "testing-runner-request", ref = safe_key(payload.dedup_key or payload.run_id or payload.module or "planned") }
end

function M.result_payload(job, payload, status, opts)
  local spec = spec_for(job)
  opts = opts or {}
  local result = {
    schema = "testing-runner.result.v1",
    job = spec.output_job,
    status = status,
    artifact_root = M.artifact_root(job, payload),
    source_ref = source_ref(payload),
    adapter = {
      name = "agentic-testing-cli",
      command = M.command(job, payload),
    },
  }
  if opts.exit_code ~= nil then result.exit_code = opts.exit_code end
  if opts.stderr ~= nil then result.stderr_excerpt = excerpt(opts.stderr) end
  return result
end

function M.run(job, payload, exec)
  M.validate_request(job, payload)
  if payload.dry_run ~= false then
    return M.result_payload(job, payload, "planned")
  end
  local run = exec or exec_sync
  if type(run) ~= "function" then
    error("testing-runner: exec-unavailable: exec_sync is required when dry_run=false")
  end
  local root = payload.agentic_testing_repo_root or "."
  local out = run("cd " .. quote(root) .. " && " .. M.command(job, payload))
  local code = type(out) == "table" and tonumber(out.exit_code) or nil
  local status = code == 0 and "passed" or "failed"
  return M.result_payload(job, payload, status, { exit_code = code or -1, stderr = type(out) == "table" and out.stderr or "" })
end

return M
