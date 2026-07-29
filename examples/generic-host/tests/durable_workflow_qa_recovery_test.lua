local durable = require("host_durable_workflow_qa")
local json_codec = require("testing_runtime.json")
local support = require("host_canonical_workflow_qa")
local supervisor_support = require("test_support.host_workflow_qa_supervisor")
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

local command_sequence = 0
local function direct_exec(argv)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  command_sequence = command_sequence + 1
  local stdout_path = os.tmpname() .. "-durable-recovery-stdout-" .. tostring(command_sequence)
  local stderr_path = os.tmpname() .. "-durable-recovery-stderr-" .. tostring(command_sequence)
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

local function write_trigger(context, _label)
  local path = context.project_root .. "/durable-workflow-qa/trigger.json"
  local trigger = {
    schema = "generic-host.durable-workflow-qa-trigger.v1",
    project_root = context.project_root,
    durable_root = context.durable_root,
    limit = 10,
  }
  local temporary = path .. ".tmp"
  write_file(temporary, json_codec.encode(trigger) .. "\n")
  assert(os.rename(temporary, path))
  local decoded = json.decode(assert(read_file(path)))
  t.eq(decoded.run_id, nil)
  return path
end

local function start_supervisor(context, label, arm_failpoint, live_pids)
  write_trigger(context, label)
  local environment = context:framework_environment(label, arm_failpoint)
  local rendered = { "env" }
  local names = {}
  for name, _ in pairs(environment) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(rendered, shell_quote(name .. "=" .. environment[name]))
  end
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
  table.insert(live_pids, pid)
  return pid, stdout_path, stderr_path
end

local function wait_for_path(path, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function poll(){if(fs.existsSync(path))process.exit(0);if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return direct_exec({ "node", "-e", script, path, tostring(timeout_seconds or 45) }).exit_code == 0
end

local function wait_for_text(path, fragment, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],fragment=process.argv[2],end=Date.now()+Number(process.argv[3])*1000;",
    "function poll(){let body='';try{body=fs.readFileSync(path,'utf8')}catch(_error){}",
    "if(body.includes(fragment))process.exit(0);if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return direct_exec({ "node", "-e", script, path, fragment, tostring(timeout_seconds or 45) }).exit_code == 0
end

local function wait_for_child_text(root, prefix, fragment, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),root=process.argv[1],prefix=process.argv[2],fragment=process.argv[3],end=Date.now()+Number(process.argv[4])*1000;",
    "function poll(){try{for(const name of fs.readdirSync(root)){if(name.startsWith(prefix)&&fs.readFileSync(root+'/'+name,'utf8').includes(fragment))process.exit(0)}}catch(_error){}",
    "if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return direct_exec({ "node", "-e", script, root, prefix, fragment,
    tostring(timeout_seconds or 45) }).exit_code == 0
end

local function assert_log_markers(path, label, markers)
  local body = read_file(path) or ""
  for _, marker in ipairs(markers) do
    if body:find(marker, 1, true) == nil then
      error("generic-host recovery test: missing " .. label .. " route marker " .. marker
        .. "\nlog=" .. body)
    end
  end
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

local function stop_live(pid, live_pids)
  stop_supervisor(pid)
  for index, value in ipairs(live_pids) do
    if value == pid then table.remove(live_pids, index) break end
  end
end

local function effect_count(context)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1];",
    "if(!fs.existsSync(path)){process.stdout.write('0');process.exit(0)}",
    "process.stdout.write(String(fs.readdirSync(path).filter(name=>name.endsWith('.json')).length));",
  })
  return tonumber(direct_exec({ "node", "-e", script, context.effect_counter_path }).stdout)
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

local function terminal_path(context)
  return context.durable_run_root .. "/records/generic-host/terminal/" .. context.run_id .. ".json"
end

local function state_diagnostic(context)
  local ok, recovered = pcall(durable.load, context.project_root, context.durable_root, context.run_id)
  if not ok then return "state_load_error=" .. tostring(recovered) end
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  if type(state) ~= "table" then return "state=nil" end
  local queues = {}
  for _, action in ipairs(state.pending_actions or {}) do table.insert(queues, tostring(action.queue)) end
  return "phase=" .. tostring(state.phase) .. " pending=" .. table.concat(queues, ",")
end

local function wait_for_terminal(context)
  for attempt = 1, 6 do
    if wait_for_path(terminal_path(context), 30) then return true end
    if attempt < 6 then write_trigger(context, "redrive-" .. tostring(attempt)) end
  end
  return false
end

local function wait_for_noop(context, label)
  local root = context.host_root .. "/framework-runtime-" .. label .. "/logs/framework-child"
  for attempt = 1, 4 do
    if wait_for_child_text(root, "generic-host.workflow_qa_supervisor-", "tag=NOOP pending_runs=0", 15) then
      return true
    end
    if attempt < 4 then write_trigger(context, "noop-" .. tostring(attempt)) end
  end
  return false
end

local function run_to_barrier(context, live_pids, label)
  local pid, stdout_path, stderr_path = start_supervisor(context, label, true, live_pids)
  local barrier_path = context.durable_run_root
    .. "/records/generic-host/barriers/post-replay-complete.json"
  if not wait_for_path(barrier_path, 180) then
    error("generic-host recovery test: supervisor did not reach completed replay barrier\nstdout="
      .. tostring(read_file(stdout_path)) .. "\nstderr=" .. tostring(read_file(stderr_path)))
  end
  local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  t.eq(state.phase, "structured-execution-pending")
  t.eq(state.pending_actions[1].queue, "testing-runner.structured_execution_request")
  local replay = recovered.records:list("testing-runner/replay")
  t.eq(#replay, 1)
  t.eq(replay[1].value.status, "completed")
  local barrier = recovered.records:read("generic-host/barriers/post-replay-complete")
  t.eq(barrier.schema, "generic-host.completed-replay-barrier.v1")
  t.eq(barrier.run_id, context.run_id)
  t.eq(barrier.failpoint, context.completed_replay_failpoint.name)
  t.eq(barrier.result_ref, replay[1].value.result_ref)
  t.eq(barrier.result_sha256, replay[1].value.result_sha256)
  t.eq(barrier.result_sha256, recovered.store:digest(barrier.result_ref))
  t.eq(barrier.replay_status, "completed")
  t.eq(effect_count(context), 1)
  t.eq(recovered:terminal_record(), nil)
  local ownership = recovered:_fixture_effect("fixture-resource-status", {
    run_id = context.run_id,
    artifact_root = context.artifact_root,
  })
  t.eq(ownership.owned, true)
  t.eq(ownership.pgid, ownership.pid)
  t.eq(#ownership.runtime_ports, 1)
  t.eq(ownership.runtime_ports[1].port, context.port)
  t.eq(ownership.workspace_path, context.workspace_root)
  stop_live(pid, live_pids)
  local surviving = recovered:_fixture_effect("fixture-resource-status", {
    run_id = context.run_id,
    artifact_root = context.artifact_root,
  })
  t.eq(surviving.owned, true)
  t.eq(surviving.pgid, ownership.pgid)
  t.eq(surviving.ownership_token, ownership.ownership_token)
  t.eq(surviving.workspace_path, context.workspace_root)
  assert_log_markers(stdout_path, "first supervisor", {
    "dept=generic-host.workflow_qa_supervisor ",
    "dept=workflow-qa.seam ",
    "dept=generic-host.workflow_qa_grant ",
  })
  return recovered, stdout_path, stderr_path
end

local function assert_terminal(context)
  local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  t.eq(state.phase, "terminal")
  t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
  t.eq(effect_count(context), 1)
  t.eq(#recovered.records:list("testing-runner/target-effects"), 1)
  local recovery = recovered.records:read("generic-host/recovery/execution")
  if context.completed_replay_failpoint ~= nil then t.eq(recovery.replayed, true) else t.eq(recovery, nil) end

  local terminal = recovered:terminal_record()
  t.eq(terminal.status, "passed")
  t.eq(terminal.counts.planned, 1)
  t.eq(terminal.counts.executed, 1)
  t.eq(terminal.counts.passed, 1)
  local aggregate_receipt = recovered.store:load(terminal.aggregate_publication_receipt_ref).value
  t.eq(aggregate_receipt.status, "published")
  t.eq(aggregate_receipt.stage, "aggregate-report")
  t.eq(aggregate_receipt.channel, "filesystem-dry-run-v1")
  local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
  t.eq(cleanup.status, "complete")
  t.eq(#cleanup.remaining_resources, 0)
  local released = recovered:_fixture_effect("fixture-release-status", {
    run_id = context.run_id,
    artifact_root = context.artifact_root,
  })
  t.eq(released.process_group_absent, true)
  t.eq(released.listeners_closed, true)
  t.eq(released.workspace_absent, true)
  t.eq(#recovered.records:list("generic-host/terminal"), 1)
  return recovered
end

local function mutate_record(path, mode)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],mode=process.argv[2],value=JSON.parse(fs.readFileSync(path,'utf8'));",
    "if(mode==='request')value.issue.number+=1;",
    "else if(mode==='authorization')value.authorization.profile_sha256='0'.repeat(64);",
    "else if(mode==='execution')value.binding.trace_id+='-mutated';",
    "else process.exit(51);",
    "const next=path+'.mutation-'+process.pid;fs.writeFileSync(next,JSON.stringify(value)+'\\n',{flag:'wx'});fs.renameSync(next,path);",
  })
  local result = direct_exec({ "node", "-e", script, path, mode })
  if result.exit_code ~= 0 then error("generic-host recovery test: durable mutation failed: " .. mode) end
end

local function replay_record_path(context, recovered)
  local entries = recovered.records:list("testing-runner/replay")
  t.eq(#entries, 1)
  return context.durable_run_root .. "/records/" .. entries[1].key .. ".json"
end

local function with_context(options, fn)
  local context = support.new(options)
  local qa_poll = context.project_root .. "/packages/workflow-qa/raisers/qa_poll.lua"
  if not os.remove(qa_poll) then error("generic-host recovery test: failed to disable fixture qa poll") end
  local live_pids = {}
  local ok, err = pcall(fn, context, live_pids)
  for _, pid in ipairs(live_pids) do pcall(stop_supervisor, pid) end
  if ok or os.getenv("FKST_KEEP_FAILED_FIXTURE") ~= "1" then
    context:cleanup()
  else
    io.stderr:write("generic-host recovery test preserved fixture: " .. context.temp_root .. "\n")
  end
  if not ok then error(err, 0) end
end

local function mutation_case(mode, expected_fragment, expected_stream)
  with_context({
    cli_only = true,
    count_effect = true,
    durable = true,
    arm_completed_replay_failpoint = true,
  }, function(context, live_pids)
    local recovered = run_to_barrier(context, live_pids, mode .. "-first")
    local execution_request
    if mode == "request" then
      mutate_record(context.durable_run_root .. "/records/workflow-qa/requests/" .. context.run_id .. ".json", mode)
    elseif mode == "authorization" then
      mutate_record(context.durable_run_root .. "/records/workflow-qa/state/" .. context.run_id .. ".json", mode)
    else
      local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      execution_request = support.copy(state.pending_actions[1].payload)
      mutate_record(replay_record_path(context, recovered), mode)
    end

    local label = mode .. "-second"
    local pid, stdout_path, stderr_path = start_supervisor(context, label, false, live_pids)
    local observed_path = expected_stream == "stdout" and stdout_path or stderr_path
    local observed = mode == "execution"
      and wait_for_child_text(context.host_root .. "/framework-runtime-" .. label .. "/logs/framework-child",
        "testing-runner.run_structured_execution-", expected_fragment, 45)
      or wait_for_text(observed_path, expected_fragment, 45)
    if not observed then
      error("generic-host recovery test: mutation did not fail closed: " .. mode
        .. "\nstdout=" .. tostring(read_file(stdout_path)) .. "\nstderr=" .. tostring(read_file(stderr_path)))
    end
    stop_live(pid, live_pids)
    recovered = durable.load(context.project_root, context.durable_root, context.run_id)
    local terminal = recovered:terminal_record()
    if mode == "execution" then
      if terminal ~= nil then t.is_true(terminal.status ~= "passed") end
    else
      t.eq(terminal, nil)
    end
    t.eq(effect_count(context), 1)
    t.eq(#recovered.records:list("testing-runner/target-effects"), 1)
    if mode == "execution" then
      local structured = supervisor_support.load_package(
        context.project_root, "testing-runner", "structured_execution")
      local result = structured.result_payload(execution_request, recovered.structured_runtime)
      t.eq(result.status, "blocked")
      t.is_true(tostring(result.stderr_excerpt):find("replay guard rejected execution", 1, true) ~= nil)
    end
  end)
end

return {
  test_durable_workflow_qa_recovers_completed_effect_without_repeating_cli = function()
    with_context({
      cli_only = true,
      count_effect = true,
      durable = true,
      arm_completed_replay_failpoint = true,
    }, function(context, live_pids)
      run_to_barrier(context, live_pids, "recovery-first")
      local pid, stdout_path, stderr_path = start_supervisor(context, "recovery-second", false, live_pids)
      if not wait_for_terminal(context) then
        error("generic-host recovery test: replacement supervisor did not reach terminal "
          .. state_diagnostic(context) .. "\nstdout=" .. tostring(read_file(stdout_path))
          .. "\nstderr=" .. tostring(read_file(stderr_path)))
      end
      stop_live(pid, live_pids)
      assert_log_markers(stdout_path, "replacement supervisor", {
        "dept=generic-host.workflow_qa_supervisor ",
        "dept=workflow-qa.seam ",
        "dept=testing-runner.run_structured_execution ",
        "dept=environment-factory.finalize ",
        "dept=test-publication.finalize_qa_run ",
        "dept=workflow-qa.terminal ",
        "dept=generic-host.workflow_qa_terminal ",
      })
      local recovered = assert_terminal(context)
      local before = record_counts(recovered)

      local noop_pid, noop_stdout, noop_stderr = start_supervisor(context, "recovery-noop", false, live_pids)
      if not wait_for_noop(context, "recovery-noop") then
        error("generic-host recovery test: terminal Host-coordinate trigger was not a no-op\nstdout="
          .. tostring(read_file(noop_stdout)) .. "\nstderr=" .. tostring(read_file(noop_stderr)))
      end
      stop_live(noop_pid, live_pids)
      local after = record_counts(durable.load(context.project_root, context.durable_root, context.run_id))
      assert_counts_equal(before, after)
      t.eq(before.profile_claims, 1)
      t.eq(before.preauthorization_claims, 1)
      t.eq(before.replay_claims, 1)
      t.eq(before.target_effects, 1)
      t.eq(before.terminal_records, 1)
    end)
  end,

  test_durable_workflow_qa_unarmed_supervisor_reaches_terminal_without_pausing = function()
    with_context({ cli_only = true, count_effect = true, durable = true }, function(context, live_pids)
      local pid, stdout_path, stderr_path = start_supervisor(context, "unarmed", false, live_pids)
      if not wait_for_terminal(context) then
        error("generic-host recovery test: unarmed supervisor did not reach terminal "
          .. state_diagnostic(context) .. "\nstdout=" .. tostring(read_file(stdout_path))
          .. "\nstderr=" .. tostring(read_file(stderr_path)))
      end
      stop_live(pid, live_pids)
      local recovered = assert_terminal(context)
      t.eq(recovered.records:read("generic-host/barriers/post-replay-complete"), nil)
    end)
  end,

  test_durable_workflow_qa_terminal_state_remains_pending_until_host_record = function()
    with_context({ cli_only = true, count_effect = true, durable = true }, function(context)
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      local expected = state.version
      state.version = expected + 1
      state.phase = "terminal"
      state.pending_actions = { {
        queue = "workflow_qa_terminal_request",
        payload = { run_id = context.run_id },
      } }
      local saved = recovered.records:cas("workflow-qa/state/" .. context.run_id, state, expected)
      t.eq(saved.saved, true)
      t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 1)

      local terminal = { run_id = context.run_id, status = "passed" }
      local recorded = recovered.records:immutable("generic-host/terminal/" .. context.run_id, terminal)
      t.eq(recorded.written, true)
      local replayed = recovered.records:immutable("generic-host/terminal/" .. context.run_id, terminal)
      t.eq(replayed.replayed, true)
      t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
      t.eq(#recovered.records:list("generic-host/terminal"), 1)
    end)
  end,

  test_durable_workflow_qa_request_binding_mutation_fails_closed = function()
    mutation_case("request", "foreign-state", "stdout")
  end,

  test_durable_workflow_qa_authorization_binding_mutation_fails_closed = function()
    mutation_case("authorization", "authorization-binding-changed", "stdout")
  end,

  test_durable_workflow_qa_execution_binding_mutation_fails_closed = function()
    mutation_case("execution", "testing-runner dept=run_structured_execution tag=BLOCKED", "stdout")
  end,
}
