local durable = require("host_durable_workflow_qa")
local json_codec = require("testing_runtime.json")
local support = require("host_canonical_workflow_qa")
local t = fkst.test

local M = {}

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

function M.read_file(path)
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
function M.exec(argv)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  command_sequence = command_sequence + 1
  local stdout_path = os.tmpname() .. "-durable-recovery-stdout-" .. tostring(command_sequence)
  local stderr_path = os.tmpname() .. "-durable-recovery-stderr-" .. tostring(command_sequence)
  local ok, _, code = os.execute(table.concat(rendered, " ")
    .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local result = {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = M.read_file(stdout_path) or "",
    stderr = M.read_file(stderr_path) or "",
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
    if M.read_file(package_root .. "/fkst.toml") == nil then
      error("generic-host recovery test: supervisor package is unavailable: " .. name)
    end
    table.insert(argv, "--package-root")
    table.insert(argv, package_root)
  end
  table.insert(argv, "--framework-bin")
  table.insert(argv, bin)
  return argv
end

function M.write_trigger(context)
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
  local decoded = json.decode(assert(M.read_file(path)))
  t.eq(decoded.run_id, nil)
  return path
end

function M.start_supervisor(context, label, arm_failpoint, live_pids)
  M.write_trigger(context)
  local environment = context:framework_environment(label, arm_failpoint)
  local rendered = { "env" }
  local names = {}
  for name, _ in pairs(environment) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do table.insert(rendered, shell_quote(name .. "=" .. environment[name])) end
  for _, item in ipairs(supervisor_argv(context)) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = context.host_root .. "/supervisor-" .. label .. ".stdout"
  local stderr_path = context.host_root .. "/supervisor-" .. label .. ".stderr"
  local pid_path = context.host_root .. "/supervisor-" .. label .. ".pid"
  local body = table.concat(rendered, " ") .. " >" .. shell_quote(stdout_path)
    .. " 2>" .. shell_quote(stderr_path) .. " & echo $! >" .. shell_quote(pid_path)
  local ok = os.execute("sh -c " .. shell_quote(body))
  if ok ~= true and ok ~= 0 then error("generic-host recovery test: failed to launch supervisor " .. label) end
  local pid = tonumber((M.read_file(pid_path) or ""):match("(%d+)"))
  if pid == nil then error("generic-host recovery test: supervisor pid is unavailable: " .. label) end
  table.insert(live_pids, pid)
  return pid, stdout_path, stderr_path
end

function M.wait_for_path(path, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function poll(){if(fs.existsSync(path))process.exit(0);if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return M.exec({ "node", "-e", script, path, tostring(timeout_seconds or 45) }).exit_code == 0
end

function M.wait_for_text(path, fragment, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],fragment=process.argv[2],end=Date.now()+Number(process.argv[3])*1000;",
    "function poll(){let body='';try{body=fs.readFileSync(path,'utf8')}catch(_error){}",
    "if(body.includes(fragment))process.exit(0);if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return M.exec({ "node", "-e", script, path, fragment, tostring(timeout_seconds or 45) }).exit_code == 0
end

function M.wait_for_child_text(root, prefix, fragment, timeout_seconds)
  local script = table.concat({
    "const fs=require('fs'),root=process.argv[1],prefix=process.argv[2],fragment=process.argv[3],end=Date.now()+Number(process.argv[4])*1000;",
    "function poll(){try{for(const name of fs.readdirSync(root)){if(name.startsWith(prefix)&&fs.readFileSync(root+'/'+name,'utf8').includes(fragment))process.exit(0)}}catch(_error){}",
    "if(Date.now()>=end)process.exit(49);setTimeout(poll,20)}poll();",
  })
  return M.exec({ "node", "-e", script, root, prefix, fragment,
    tostring(timeout_seconds or 45) }).exit_code == 0
end

function M.assert_log_markers(path, label, markers)
  local body = M.read_file(path) or ""
  for _, marker in ipairs(markers) do
    if body:find(marker, 1, true) == nil then
      error("generic-host recovery test: missing " .. label .. " route marker " .. marker .. "\nlog=" .. body)
    end
  end
end

function M.stop_supervisor(pid)
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
  local result = M.exec({ "node", "-e", script, tostring(pid) })
  if result.exit_code ~= 0 then error("generic-host recovery test: supervisor process tree did not terminate") end
end

function M.stop_live(pid, live_pids)
  M.stop_supervisor(pid)
  for index, value in ipairs(live_pids) do
    if value == pid then table.remove(live_pids, index) break end
  end
end

local function counter_count(path)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1];",
    "if(!path||!fs.existsSync(path)){process.stdout.write('0');process.exit(0)}",
    "process.stdout.write(String(fs.readdirSync(path).filter(name=>name.endsWith('.json')).length));",
  })
  return tonumber(M.exec({ "node", "-e", script, path or "" }).stdout)
end

function M.effect_count(context)
  return counter_count(context.cli_effect_counter_path or context.effect_counter_path)
end

function M.http_effect_count(context)
  return counter_count(context.http_effect_counter_path)
end

function M.total_effect_count(context)
  return M.effect_count(context) + M.http_effect_count(context)
end

function M.terminal_path(context)
  return context.durable_run_root .. "/records/generic-host/terminal/" .. context.run_id .. ".json"
end

function M.wait_for_terminal(context)
  for attempt = 1, 6 do
    if M.wait_for_path(M.terminal_path(context), 30) then return true end
    if attempt < 6 then M.write_trigger(context) end
  end
  return false
end

function M.wait_for_noop(context, label)
  local root = context.host_root .. "/framework-runtime-" .. label .. "/logs/framework-child"
  for attempt = 1, 4 do
    if M.wait_for_child_text(root, "generic-host.workflow_qa_supervisor-", "tag=NOOP pending_runs=0", 15) then
      return true
    end
    if attempt < 4 then M.write_trigger(context) end
  end
  return false
end

function M.with_context(options, fn)
  local context = support.new(options)
  local qa_poll = context.project_root .. "/packages/workflow-qa/raisers/qa_poll.lua"
  if not os.remove(qa_poll) then error("generic-host recovery test: failed to disable fixture qa poll") end
  local live_pids = {}
  local ok, err = pcall(fn, context, live_pids)
  for _, pid in ipairs(live_pids) do pcall(M.stop_supervisor, pid) end
  if ok or os.getenv("FKST_KEEP_FAILED_FIXTURE") ~= "1" then
    context:cleanup()
  else
    io.stderr:write("generic-host recovery test preserved fixture: " .. context.temp_root .. "\n")
  end
  if not ok then error(err, 0) end
end

return M
