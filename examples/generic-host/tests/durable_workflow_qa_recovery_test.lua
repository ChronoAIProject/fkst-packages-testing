local durable = require("host_durable_workflow_qa")
local json_codec = require("testing_runtime.json")
local support = require("host_canonical_workflow_qa")
local supervisor = require("host_workflow_qa_supervisor")
local t = fkst.test

local PACKAGE_NAMES = {
  "generic-host",
  "environment-factory",
  "testing-design",
  "browser-readiness",
  "module-testing-pipeline",
  "module-test-loop",
  "testing-runner",
  "test-artifacts",
  "test-publication",
  "workflow-qa",
  "consensus",
  "github-proxy",
}

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if handle == nil then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_file(path, body)
  local parent = tostring(path):match("^(.*)/[^/]+$")
  if parent ~= nil then os.execute("mkdir -p " .. shell_quote(parent)) end
  local handle = assert(io.open(path, "wb"))
  handle:write(body)
  handle:close()
end

local function direct_exec(argv)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = os.tmpname() .. "-durable-recovery-stdout"
  local stderr_path = os.tmpname() .. "-durable-recovery-stderr"
  local ok, _, code = os.execute(table.concat(rendered, " ")
    .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local result = {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = read_file(stdout_path) or "",
    stderr = read_file(stderr_path) or "",
  }
  os.remove(stdout_path)
  os.remove(stderr_path)
  return result
end

local function supervisor_argv(context)
  local bin = os.getenv("BIN")
  if type(bin) ~= "string" or bin == "" then error("generic-host recovery test: BIN is unavailable") end
  local argv = { bin, "supervise", "--project-root", context.project_root }
  for _, name in ipairs(PACKAGE_NAMES) do
    local package_root = context.project_root .. "/packages/" .. name
    if read_file(package_root .. "/fkst.toml") == nil then
      error("generic-host recovery test: supervisor package is unavailable: " .. name)
    end
    table.insert(argv, "--package-root")
    table.insert(argv, package_root)
  end
  table.insert(argv, "--framework-bin")
  table.insert(argv, bin)
  return argv
end

local function start_supervisor(context, label)
  local rendered = {
    "env",
    "FKST_RUNTIME_ROOT=" .. shell_quote(context.host_root .. "/framework-runtime-" .. label),
    "FKST_DURABLE_ROOT=" .. shell_quote(context.host_root .. "/framework-durable-" .. label),
  }
  for _, item in ipairs(supervisor_argv(context)) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = context.host_root .. "/supervisor-" .. label .. ".stdout"
  local stderr_path = context.host_root .. "/supervisor-" .. label .. ".stderr"
  local pid_path = context.host_root .. "/supervisor-" .. label .. ".pid"
  local body = table.concat(rendered, " ") .. " >" .. shell_quote(stdout_path)
    .. " 2>" .. shell_quote(stderr_path) .. " & echo $! >" .. shell_quote(pid_path)
  local ok = os.execute("sh -c " .. shell_quote(body))
  if ok ~= true and ok ~= 0 then error("generic-host recovery test: failed to launch supervisor " .. label) end
  local pid = tonumber((read_file(pid_path) or ""):match("(%d+)"))
  if pid == nil then error("generic-host recovery test: supervisor pid is unavailable: " .. label) end
  return pid, stdout_path, stderr_path
end

local function wait_for_path(path, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function poll(){if(fs.existsSync(path))process.exit(0);if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return direct_exec({ "node", "-e", script, path, tostring(timeout_seconds or 30) }).exit_code == 0
end

local function wait_for_text(path, fragment, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],fragment=process.argv[2],end=Date.now()+Number(process.argv[3])*1000;",
    "function poll(){let body='';try{body=fs.readFileSync(path,'utf8')}catch(_error){}",
    "if(body.includes(fragment))process.exit(0);if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return direct_exec({ "node", "-e", script, path, fragment, tostring(timeout_seconds or 30) }).exit_code == 0
end

local function stop_supervisor(pid)
  local script = table.concat({
    "const cp=require('child_process'),root=Number(process.argv[1]);",
    "const rows=cp.execFileSync('ps',['-axo','pid=,ppid='],{encoding:'utf8'}).trim().split(/\\n+/).map(line=>line.trim().split(/\\s+/).map(Number));",
    "const children=new Map();for(const [pid,ppid] of rows){if(!children.has(ppid))children.set(ppid,[]);children.get(ppid).push(pid)}",
    "const tree=[];function visit(pid){for(const child of children.get(pid)||[]){visit(child);tree.push(child)}}visit(root);tree.push(root);",
    "for(const target of tree){try{process.kill(target,'SIGTERM')}catch(_error){}}",
    "const end=Date.now()+5000;while(Date.now()<end){if(tree.every(target=>{try{process.kill(target,0);return false}catch(_error){return true}}))process.exit(0);Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20)}",
    "for(const target of tree){try{process.kill(target,'SIGKILL')}catch(_error){}}",
    "if(tree.some(target=>{try{process.kill(target,0);return true}catch(_error){return false}}))process.exit(50);",
  })
  local result = direct_exec({ "node", "-e", script, tostring(pid) })
  if result.exit_code ~= 0 then error("generic-host recovery test: supervisor process tree did not terminate") end
end

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local function record_counts(context)
  return {
    environment_effects = #context.records:list("environment-factory/effects"),
    publications = #context.records:list("test-publication/effects"),
    profile_claims = #context.records:list("generic-host/profile-approval"),
    preauthorization_claims = #context.records:list("generic-host/preauthorization"),
    replay_claims = #context.records:list("testing-runner/replay"),
    target_effects = #context.records:list("testing-runner/target-effects"),
    terminal_records = #context.records:list("generic-host/terminal"),
  }
end

local function assert_counts_equal(left, right)
  for key, value in pairs(left) do t.eq(right[key], value) end
end

return {
  test_durable_workflow_qa_restarts_after_completed_execution_without_repeating_effect = function()
    local context = support.new({ cli_only = true, count_effect = true, durable = true })
    local live_pids = {}
    local ok, err = pcall(function()
      t.is_true(read_file(context.project_root .. "/fkst.workspace.toml") ~= nil)
      local trigger_path = context.project_root .. "/durable-workflow-qa/recover.json"
      write_file(trigger_path, json_codec.encode({
        schema = "generic-host.durable-workflow-qa-trigger.v1",
        project_root = context.project_root,
        durable_root = context.durable_root,
        limit = 10,
      }) .. "\n")
      local trigger = json.decode(assert(read_file(trigger_path)))
      t.eq(trigger.run_id, nil)

      local first_pid, first_stdout, first_stderr = start_supervisor(context, "first")
      table.insert(live_pids, first_pid)
      local barrier_path = context.durable_run_root
        .. "/records/generic-host/barriers/post-replay-complete.json"
      if not wait_for_path(barrier_path, 45) then
        error("generic-host recovery test: first supervisor did not reach the durable barrier\nstdout="
          .. tostring(read_file(first_stdout)) .. "\nstderr=" .. tostring(read_file(first_stderr)))
      end
      stop_supervisor(first_pid)
      table.remove(live_pids)

      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      t.eq(state.phase, "structured-execution-pending")
      t.eq(state.pending_actions[1].queue, "testing-runner.structured_execution_request")
      t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 1)
      t.eq(#recovered.records:list("workflow-qa/requests"), 1)
      t.eq(#recovered.records:list("testing-runner/replay"), 1)
      t.eq(recovered.records:list("testing-runner/replay")[1].value.status, "completed")
      t.eq(recovered:terminal_record(), nil)
      t.eq(tonumber((read_file(context.effect_counter_path) or ""):match("(%d+)")), 1)

      local stale = recovered.records:cas("workflow-qa/state/" .. recovered.run_id,
        support.copy(state), state.version - 1)
      t.eq(stale.saved, false)
      t.eq(stale.stale, true)

      local workflow = supervisor.load_package(context.project_root, "workflow-qa", "core")
      local foreign_request = support.copy(recovered.request)
      foreign_request.issue.number = foreign_request.issue.number + 1
      expect_failure("foreign-state", function()
        workflow.start(foreign_request, recovered.workflow_runtime)
      end)

      local authorization_ports = {}
      for name, value in pairs(recovered.workflow_runtime) do authorization_ports[name] = value end
      authorization_ports.load_state = function(path)
        local value = recovered.workflow_runtime.load_state(path)
        value.authorization.profile_sha256 = string.rep("0", 64)
        return value
      end
      expect_failure("authorization-binding-changed", function()
        workflow.start(recovered.request, authorization_ports)
      end)

      local structured = supervisor.load_package(context.project_root, "testing-runner", "structured_execution")
      local foreign_execution = support.copy(state.pending_actions[1].payload)
      foreign_execution.trace_id = foreign_execution.trace_id .. "-foreign"
      local blocked = structured.run(foreign_execution, recovered.structured_runtime)
      t.eq(blocked.status, "blocked")
      t.eq(tonumber((read_file(context.effect_counter_path) or ""):match("(%d+)")), 1)

      local second_pid, second_stdout, second_stderr = start_supervisor(context, "second")
      table.insert(live_pids, second_pid)
      local terminal_path = context.durable_run_root .. "/records/generic-host/terminal/"
        .. context.run_id .. ".json"
      if not wait_for_path(terminal_path, 45) then
        error("generic-host recovery test: restarted supervisor did not reach terminal\nstdout="
          .. tostring(read_file(second_stdout)) .. "\nstderr=" .. tostring(read_file(second_stderr)))
      end
      stop_supervisor(second_pid)
      table.remove(live_pids)

      recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      t.eq(state.phase, "terminal")
      t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
      t.eq(recovered.records:read("generic-host/recovery/execution").replayed, true)
      t.eq(tonumber((read_file(context.effect_counter_path) or ""):match("(%d+)")), 1)
      t.eq(#recovered.records:list("testing-runner/target-effects"), 1)

      local terminal = recovered:terminal_record()
      t.eq(terminal.status, "passed")
      t.eq(terminal.counts.planned, 1)
      t.eq(terminal.counts.executed, 1)
      t.eq(terminal.counts.passed, 1)
      local aggregate_receipt = recovered.store:load(terminal.aggregate_publication_receipt_ref)
      t.eq(aggregate_receipt.value.status, "published")
      t.eq(aggregate_receipt.value.stage, "aggregate-report")
      local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      local absent = os.execute("test ! -e " .. shell_quote(context.workspace_root))
      t.is_true(absent == true or absent == 0)

      local before = record_counts(recovered)
      local third_pid, third_stdout = start_supervisor(context, "third")
      table.insert(live_pids, third_pid)
      if not wait_for_text(third_stdout, "dept=generic-host.workflow_qa_supervisor delivery_id=", 45) then
        error("generic-host recovery test: terminal replay delivery was not acknowledged\nstdout="
          .. tostring(read_file(third_stdout)))
      end
      stop_supervisor(third_pid)
      table.remove(live_pids)
      local after = record_counts(durable.load(context.project_root, context.durable_root, context.run_id))
      assert_counts_equal(before, after)
      t.eq(before.profile_claims, 1)
      t.eq(before.preauthorization_claims, 1)
      t.eq(before.replay_claims, 1)
      t.eq(before.target_effects, 1)
      t.eq(before.terminal_records, 1)
    end)
    for _, pid in ipairs(live_pids) do pcall(stop_supervisor, pid) end
    context:cleanup()
    if not ok then error(err, 0) end
  end,
}
