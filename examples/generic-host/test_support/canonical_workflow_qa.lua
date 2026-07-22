local browser_readiness = require("contract.browser_readiness")
local execution = require("contract.structured_execution")
local json_codec = require("testing_runtime.json")
local project_profile = require("contract.project_profile")
local workflow_qa = require("contract.workflow_qa")

local M = {}

local project_root
local command_sequence = 0

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function equal(left, right)
  if left == right then return true end
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then return false end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if handle == nil then return nil end
  local value = handle:read("*a")
  handle:close()
  return value
end

local function write_file(path, value)
  local parent = tostring(path):match("^(.*)/[^/]+$")
  if parent ~= nil then
    os.execute("mkdir -p " .. shell_quote(parent))
  end
  local handle = assert(io.open(path, "wb"))
  handle:write(value)
  handle:close()
end

local function direct_exec(argv, cwd)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local command = table.concat(rendered, " ")
  if cwd ~= nil then command = "cd " .. shell_quote(cwd) .. " && " .. command end
  command_sequence = command_sequence + 1
  local stdout_path = os.tmpname() .. "-canonical-stdout-" .. tostring(command_sequence)
  local stderr_path = os.tmpname() .. "-canonical-stderr-" .. tostring(command_sequence)
  local ok, _, code = os.execute(command .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local stdout = read_file(stdout_path) or ""
  local stderr = read_file(stderr_path) or ""
  os.remove(stdout_path)
  os.remove(stderr_path)
  return {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = stdout,
    stderr = stderr,
  }
end

local function require_exec(argv, cwd)
  local result = direct_exec(argv, cwd)
  if result.exit_code ~= 0 then
    error("canonical host command failed: " .. tostring(argv[1]) .. " exit=" .. tostring(result.exit_code)
      .. " stderr=" .. tostring(result.stderr), 0)
  end
  return result.stdout
end

local function remove_tree(path, allowed_prefix)
  local script = table.concat({
    "const fs=require('fs');const path=process.argv[1],prefix=process.argv[2];",
    "if(!path.startsWith(prefix)||path===prefix)process.exit(44);",
    "fs.rmSync(path,{recursive:true,force:true});",
  })
  require_exec({ "node", "-e", script, path, allowed_prefix })
end

project_root = require_exec({ "node", "-e", "process.stdout.write(process.cwd())" }):gsub("%s+$", "")

local function absolute(path)
  if tostring(path):sub(1, 1) == "/" then return path end
  return project_root .. "/" .. path
end

local function sha256_bytes(bytes)
  command_sequence = command_sequence + 1
  local input = os.tmpname() .. "-canonical-sha-input-" .. tostring(command_sequence)
  write_file(input, bytes)
  local body = require_exec({
    "node", "-e",
    "const fs=require('fs'),crypto=require('crypto');process.stdout.write(crypto.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'))",
    input,
  })
  os.remove(input)
  local digest = body:match("([0-9a-f]+)")
  if type(digest) ~= "string" or #digest ~= 64 then error("canonical host sha256 unavailable") end
  return digest
end

local function reserve_port()
  local script = table.concat({
    "const net=require('net');const server=net.createServer();",
    "server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>process.stdout.write(String(port)))})",
  })
  return assert(tonumber(require_exec({ "node", "-e", script })))
end

local function ref(path)
  return { kind = "artifact", ref = path }
end

local Store = {}
Store.__index = Store

local function decode_json(body)
  if type(json) ~= "table" or type(json.decode) ~= "function" then return nil end
  local ok, value = pcall(json.decode, body)
  return ok and value or nil
end

function Store.new()
  return setmetatable({ artifacts = {}, writes = {} }, Store)
end

function Store:_from_disk(path)
  local body = read_file(absolute(path))
  if body == nil or body == "" then return nil end
  local value = decode_json(body)
  if type(value) ~= "table" then value = body end
  local entry = { value = value, raw = body, digest = sha256_bytes(body) }
  self.artifacts[path] = entry
  return entry
end

function Store:load(path)
  local entry = self.artifacts[path] or self:_from_disk(path)
  return entry and copy(entry) or nil
end

function Store:write(path, value)
  local existing = self.artifacts[path] or self:_from_disk(path)
  if existing ~= nil then return equal(existing.value, value) end
  local body = json_codec.encode(value) .. "\n"
  return self:write_raw(path, body, value)
end

function Store:write_raw(path, body, decoded)
  local existing = self.artifacts[path] or self:_from_disk(path)
  if existing ~= nil then return existing.raw == body end
  if decoded == nil then
    local value = decode_json(body)
    decoded = type(value) == "table" and value or body
  end
  write_file(absolute(path), body)
  self.artifacts[path] = { value = copy(decoded), raw = body, digest = sha256_bytes(body) }
  self.writes[path] = (self.writes[path] or 0) + 1
  return true
end

function Store:digest(path)
  local entry = self.artifacts[path] or self:_from_disk(path)
  return entry and entry.digest or nil
end

function Store:write_count(path)
  return self.writes[path] or 0
end

local function artifact_reference(schema, path, digest)
  return {
    schema = "testing-design.artifact-reference.v1",
    artifact_schema = schema,
    artifact_pointer = path,
    artifact_digest = digest,
  }
end

local function spawn_process(argv, cwd, root)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = root .. "/server.stdout"
  local stderr_path = root .. "/server.stderr"
  local pid_path = root .. "/server.pid"
  os.execute("mkdir -p " .. shell_quote(root))
  local body = "cd " .. shell_quote(cwd) .. " && " .. table.concat(rendered, " ")
    .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path)
    .. " & echo $! >" .. shell_quote(pid_path)
  local ok = os.execute("sh -c " .. shell_quote(body))
  if ok ~= true and ok ~= 0 then error("canonical fixture server failed to start") end
  local pid = tonumber((read_file(pid_path) or ""):match("(%d+)"))
  if pid == nil then error("canonical fixture server pid unavailable") end
  return pid
end

local function wait_http(url, timeout_seconds)
  local script = table.concat({
    "const http=require('http');const url=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function probe(){const req=http.get(url,res=>{res.resume();if(res.statusCode===200)process.exit(0);retry()});",
    "req.on('error',retry);req.setTimeout(250,()=>req.destroy());}",
    "function retry(){if(Date.now()>=end)process.exit(47);setTimeout(probe,20)}probe();",
  })
  return direct_exec({ "node", "-e", script, url, tostring(timeout_seconds or 10) }).exit_code == 0
end

local function http_request(request, timeout_seconds)
  local script = table.concat({
    "const http=require('http'),u=new URL(process.argv[1]);",
    "const req=http.request({hostname:u.hostname,port:u.port,path:u.pathname+u.search,method:process.argv[2],timeout:Number(process.argv[3])*1000},res=>{",
    "let body='';res.setEncoding('utf8');res.on('data',c=>body+=c);res.on('end',()=>process.stdout.write(JSON.stringify({status:res.statusCode,body})));",
    "});req.on('timeout',()=>req.destroy(new Error('timeout')));req.on('error',error=>{process.stderr.write(error.message);process.exit(48)});req.end();",
  })
  local result = direct_exec({ "node", "-e", script, request.url, request.method, tostring(timeout_seconds or 10) })
  if result.exit_code ~= 0 then error(result.stderr) end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("canonical host JSON decoder is unavailable")
  end
  return json.decode(result.stdout)
end

local Context = {}
Context.__index = Context

function Context:_record_effect(id, kind, value)
  if self.effects[id] == nil then
    self.effects[id] = copy(value or true)
    table.insert(self.effect_order, { id = id, kind = kind })
  end
  return copy(self.effects[id])
end

function Context:_environment_runtime()
  local context = self
  local states = {}
  local revisions = {}
  local effects = {}
  local workspaces = {}
  local processes = {}

  local function replay(id, fn)
    if effects[id] ~= nil then return copy(effects[id]) end
    local value = fn()
    effects[id] = copy(value)
    context:_record_effect(id, "environment", value)
    return copy(value)
  end

  return {
    load_state = function(pointer)
      local path = pointer.ref
      if states[path] == nil then return nil end
      return { authenticated = true, state = copy(states[path]), revision = revisions[path] }
    end,
    save_state = function(pointer, state, expected)
      local path = pointer.ref
      local revision = revisions[path] or 0
      if revision ~= expected then return { stale = true, revision = revision } end
      revisions[path] = revision + 1
      states[path] = copy(state)
      return { saved = true, revision = revisions[path] }
    end,
    load_authorization_bundle = function()
      return {
        profile = copy(context.profile),
        approval = copy(context.approval),
        receipt = copy(context.validation_receipt),
        context = copy(context.authorization_context),
      }
    end,
    authorize_claim_ports = function(request)
      return replay(request.effect_id, function()
        local snapshot = request.authorize()
        return {
          status = "passed",
          profile_snapshot = snapshot,
          cleanup_ref = { kind = "port-lease", ref = context.run_id .. "-ports" },
          runtime_ports = copy(request.runtime_ports),
          deadline_epoch_seconds = 1784685600,
          request_binding = copy(request.request_binding),
        }
      end)
    end,
    checkout = function(request)
      return replay(request.effect_id, function()
        remove_tree(context.workspace_root, context.temp_root .. "/")
        require_exec({ "git", "clone", "--quiet", context.source_root, context.workspace_root })
        require_exec({ "git", "checkout", "--quiet", context.commit_sha }, context.workspace_root)
        local resolved = require_exec({ "git", "rev-parse", "HEAD" }, context.workspace_root):match("([0-9a-f]+)")
        if resolved ~= context.commit_sha then error("canonical checkout resolved the wrong commit") end
        local workspace_ref = { kind = "workspace", ref = context.run_id .. "-workspace" }
        workspaces[workspace_ref.ref] = context.workspace_root
        return {
          status = "passed",
          resolved_commit = resolved,
          workspace_ref = workspace_ref,
          cleanup_ref = { kind = "workspace-cleanup", ref = context.run_id .. "-workspace" },
        }
      end)
    end,
    remaining_budget = function() return 120 end,
    create_readiness_attempt = function(request)
      return replay(request.effect_id, function()
        local path = request.artifact_root .. "/readiness-attempts/attempt-1.json"
        local value = {
          schema = "canonical-qa.readiness-attempt.v1",
          operation_id = request.operation_id,
          base_url = request.base_url,
          sessions = copy(request.sessions),
          trace_id = request.trace_id,
          dedup_key = request.dedup_key,
        }
        assert(context.store:write(path, value))
        return {
          status = "passed",
          attempt_id = "attempt-1",
          attempt_ref = ref(path),
          attempt_sha256 = context.store:digest(path),
        }
      end)
    end,
    run_argv = function(request)
      return replay(request.effect_id, function()
        local workspace = workspaces[request.workspace_ref.ref]
        if workspace == nil then error("canonical workspace is unavailable") end
        if request.mode == "supervised" then
          local pid = spawn_process(request.argv, workspace, context.host_root)
          local cleanup_ref = { kind = "process-cleanup", ref = context.run_id .. "-application" }
          processes[cleanup_ref.ref] = pid
          return {
            status = "running",
            cleanup_ref = cleanup_ref,
            early_exit = false,
            runtime_ports = copy(request.runtime_ports),
          }
        end
        local result = direct_exec(request.argv, workspace)
        local outcome = { status = result.exit_code == 0 and "passed" or "blocked" }
        if request.requires_frozen_dependencies then outcome.frozen_dependencies_enforced = true end
        return outcome
      end)
    end,
    wait_readiness = function(request)
      return replay(request.effect_id, function()
        for _, check in ipairs(request.checks or {}) do
          if check.type == "http" then
            if not wait_http(check.url, request.timeout_seconds) then return { status = "blocked" } end
          elseif check.type == "argv" then
            local workspace = workspaces[request.workspace_ref.ref]
            if direct_exec(check.argv, workspace).exit_code ~= 0 then return { status = "blocked" } end
          else
            return { status = "blocked" }
          end
        end
        return { status = "ready" }
      end)
    end,
    cleanup = function(request)
      return replay(request.effect_id, function()
        local cleanup = request.cleanup_ref or {}
        if cleanup.kind == "process-cleanup" then
          local pid = processes[cleanup.ref]
          if pid ~= nil then
            os.execute("kill " .. tostring(pid) .. " >/dev/null 2>&1 || true")
            processes[cleanup.ref] = nil
          end
        elseif cleanup.kind == "workspace-cleanup" then
          remove_tree(context.workspace_root, context.temp_root .. "/")
          workspaces[context.run_id .. "-workspace"] = nil
        end
        return { status = "cleaned" }
      end)
    end,
    write_receipt = function(request)
      return replay(request.effect_id, function()
        if context.store:write(request.receipt_ref.ref, request.receipt) ~= true then
          return { status = "blocked" }
        end
        return { status = "passed" }
      end)
    end,
  }
end

function Context:_workflow_runtime()
  local context = self
  local state
  local version = 0
  return {
    load_state = function(path)
      if path ~= context.request.state_ref then return nil end
      return state and copy(state) or nil
    end,
    load_run = function(trace_id, dedup_key)
      if trace_id == context.request.trace_id and dedup_key == context.request.dedup_key then
        return copy(context.request)
      end
    end,
    load_run_by_id = function(run_id)
      if run_id == context.run_id then return copy(context.request) end
    end,
    list_pending_runs = function()
      if state ~= nil and state.phase ~= "terminal" then return { copy(context.request) } end
      return {}
    end,
    save_state = function(path, value, expected)
      if path ~= context.request.state_ref or expected ~= version then return false end
      state = copy(value)
      version = value.version
      context.workflow_state = copy(value)
      return true
    end,
    load_artifact = function(path) return context.store:load(path) end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    artifact_digest = function(path) return context.store:digest(path) end,
  }
end

function Context:_module_loop_runtime()
  local context = self
  local states = {}
  local versions = {}
  return {
    load_state = function(path) return states[path] and copy(states[path]) or nil end,
    save_state = function(path, value, expected)
      local version = versions[path] or 0
      if expected ~= version then return false end
      versions[path] = value.version
      states[path] = copy(value)
      return true
    end,
    list_pending_states = function()
      local out = {}
      for path, state in pairs(states) do
        if state.phase ~= "terminal" then table.insert(out, path) end
      end
      table.sort(out)
      return out
    end,
    artifact_digest = function(path) return context.store:digest(path) end,
  }
end

function Context:_testing_design_runtime()
  local context = self
  local result
  return {
    analyze = function(request)
      if result ~= nil then
        local replay = copy(result)
        replay.replayed = true
        return replay
      end
      local root = request.artifact_root
      local docs = {
        repository_analysis = {
          path = root .. "/repository-analysis.v1.json",
          schema = "testing-design.repository-analysis.v1",
          value = { schema = "testing-design.repository-analysis.v1", repository = copy(request.repository), modules = { "service" } },
        },
        requirements_index = {
          path = root .. "/requirements-index.v1.json",
          schema = "testing-design.requirements-index.v1",
          value = { schema = "testing-design.requirements-index.v1", requirements = { { id = "REQ-HEALTH", priority = "P0" } } },
        },
        traceability_seed = {
          path = root .. "/traceability-seed.v1.json",
          schema = "testing-design.traceability-seed.v1",
          value = { schema = "testing-design.traceability-seed.v1", links = { { requirement = "REQ-HEALTH", module = "service" } } },
        },
      }
      local refs = {}
      for key, doc in pairs(docs) do
        assert(context.store:write(doc.path, doc.value))
        refs[key] = artifact_reference(doc.schema, doc.path, context.store:digest(doc.path))
      end
      result = {
        status = "complete",
        replayed = false,
        analysis_key = sha256_bytes(json_codec.encode(refs)),
        context = {
          schema = "testing-design.context-reference.v1",
          analysis_key = sha256_bytes(json_codec.encode(refs)),
          repository_analysis = refs.repository_analysis,
          requirements_index = refs.requirements_index,
          traceability_seed = refs.traceability_seed,
        },
      }
      return copy(result)
    end,
  }
end

function Context:_structured_runtime()
  local context = self
  local claims = {}
  return {
    load_artifact = function(path) return context.store:load(path) end,
    now = function() return "2026-07-22T00:20:00Z" end,
    verify_grant = function(request)
      local grant = request.grant
      return {
        grant_sha256 = request.grant_sha256,
        authority = copy(grant.authority),
        policy_revision = grant.policy_revision,
        evidence_ref = copy(grant.evidence_ref),
      }
    end,
    replay_guard = function(request)
      local claim = claims[request.grant_id]
      if claim ~= nil then
        if claim.completed then return { status = "completed", result_ref = claim.result_ref } end
        return { status = "claimed", claim_id = claim.claim_id }
      end
      claim = { claim_id = context.run_id .. "-execution-claim" }
      claims[request.grant_id] = claim
      context.execution_claims = context.execution_claims + 1
      return { status = "claimed", claim_id = claim.claim_id }
    end,
    exec_argv = function(argv)
      table.insert(context.target_effects, { kind = "cli", argv = copy(argv) })
      return direct_exec(argv, context.workspace_root)
    end,
    http_request = function(request, timeout_seconds)
      table.insert(context.target_effects, { kind = "http", method = request.method, url = request.url })
      return http_request(request, timeout_seconds)
    end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    load_result = function(path)
      local artifact = context.store:load(path)
      if artifact == nil then return nil end
      local value = artifact.value
      return {
        schema = "testing-runner.structured-execution-summary.v1",
        status = value.status,
        classification = value.classification,
        mode = "structured-api-cli",
        artifact_root = context.request.structured_execution.artifact_root,
        case_count = value.case_count,
        passed_count = value.passed_count,
        failed_count = value.failed_count,
        skipped_count = value.skipped_count,
        error_count = value.error_count,
        test_plan_path = value.test_plan_path,
        case_results_path = value.case_results_path,
        execution_path = value.execution_path,
        replayed = true,
      }
    end,
    complete_replay = function(claim, result_ref)
      for _, stored in pairs(claims) do
        if stored.claim_id == claim.claim_id then
          stored.completed = true
          stored.result_ref = result_ref
          return true
        end
      end
      return false
    end,
  }
end

function Context:_publication_runtime()
  local context = self
  local ledgers = {}
  return {
    load_ledger = function(path) return ledgers[path] and copy(ledgers[path]) or nil end,
    save_ledger = function(path, value, expected)
      local current = ledgers[path]
      local version = current and current.version or 0
      if version ~= expected then return false end
      ledgers[path] = copy(value)
      context.publication_ledger = copy(value)
      return true
    end,
    publish_artifact = function(request)
      local id = table.concat({ "publish", request.run_id, request.stage, tostring(request.attempt), request.digest }, "/")
      local existing = context.publications[id]
      if existing ~= nil then return copy(existing) end
      local value = {
        status = "published",
        remote_url = "https://github.com/" .. request.repository.slug .. "/blob/" .. request.repository.commit_sha
          .. "/qa/" .. request.stage .. "-" .. tostring(request.attempt) .. ".json",
        digest = request.digest,
        source_commit = request.repository.commit_sha,
        receipt_ref = context.artifact_root .. "/published/" .. request.stage .. "-" .. tostring(request.attempt) .. ".json",
      }
      context.publications[id] = copy(value)
      context.publication_count = context.publication_count + 1
      return value
    end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    write_report = function(path, value)
      if context.store:write(path, value) ~= true then return { status = "blocked" } end
      return { status = "written", digest = context.store:digest(path) }
    end,
    load_artifact = function(path) return context.store:load(path) end,
  }
end

function Context:_generic_host_runtime()
  local context = self
  local preauthorization_claim
  return {
    load_artifact = function(path) return context.store:load(path) end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    artifact_digest = function(path) return context.store:digest(path) end,
    claim_preauthorization = function(value)
      if preauthorization_claim ~= nil then
        if not equal(preauthorization_claim.value, value) then return { status = "blocked" } end
        return { status = "claimed", claim_id = preauthorization_claim.claim_id, replayed = true }
      end
      preauthorization_claim = { value = copy(value), claim_id = context.run_id .. "-preauthorization" }
      context.preauthorization_claims = context.preauthorization_claims + 1
      return { status = "claimed", claim_id = preauthorization_claim.claim_id }
    end,
    grant_values = function()
      return {
        grant_id = context.run_id .. "-grant",
        evidence_ref = { kind = "signed-attestation", ref = context.run_id .. "-execution-grant" },
        issued_at = "2026-07-22T00:15:00Z",
        expires_at = "2026-07-22T00:45:00Z",
        now = "2026-07-22T00:20:00Z",
      }
    end,
    record_terminal = function(value)
      if context.terminal ~= nil and not equal(context.terminal, value) then return false end
      if context.terminal == nil then context.terminal_records = context.terminal_records + 1 end
      context.terminal = copy(value)
      return true
    end,
  }
end

function Context:run_lifecycle()
  return require("test_support.canonical_lifecycle_driver").run(self, project_root)
end

function Context:with_globals(fn)
  local values = {
    environment_factory_runtime = self.environment_runtime,
    workflow_qa_runtime = self.workflow_runtime,
    module_test_loop_runtime = self.module_loop_runtime,
    testing_design_runtime = self.testing_design_runtime,
    structured_execution_runtime = self.structured_runtime,
    qa_publication_runtime = self.publication_runtime,
    generic_host_workflow_qa_runtime = self.generic_host_runtime,
  }
  local previous = {}
  for name, value in pairs(values) do
    previous[name] = rawget(_G, name)
    rawset(_G, name, value)
  end
  local ok, result = xpcall(fn, function(value) return tostring(value) end)
  for name, value in pairs(previous) do rawset(_G, name, value) end
  if not ok then error(result, 0) end
  return result
end

function Context:cleanup()
  local pid_body = read_file(self.host_root .. "/server.pid")
  local pid = pid_body and tonumber(pid_body:match("(%d+)")) or nil
  if pid ~= nil then os.execute("kill " .. tostring(pid) .. " >/dev/null 2>&1 || true") end
  remove_tree(self.temp_root, "/tmp/fkst-generic-host-canonical-")
  remove_tree(absolute(self.artifact_root), project_root .. "/.testing/runs/canonical-workflow-qa-")
end

function M.new()
  local port = reserve_port()
  local cdp_port = reserve_port()
  local run_id = "canonical-workflow-qa-" .. tostring(port)
  local artifact_root = ".testing/runs/" .. run_id
  local temp_root = "/tmp/fkst-generic-host-" .. run_id
  local source_root = temp_root .. "/source"
  local workspace_root = temp_root .. "/workspace"
  local host_root = temp_root .. "/host"
  require_exec({ "rm", "-rf", temp_root, absolute(artifact_root) })
  require_exec({ "mkdir", "-p", source_root, host_root })
  require_exec({
    "node", "-e",
    "const fs=require('fs');fs.cpSync(process.argv[1],process.argv[2],{recursive:true});",
    absolute("examples/generic-host/fixtures/canonical-qa"), source_root,
  })
  require_exec({ "git", "init", "--quiet" }, source_root)
  require_exec({ "git", "config", "user.email", "fixture@example.invalid" }, source_root)
  require_exec({ "git", "config", "user.name", "Canonical QA Fixture" }, source_root)
  require_exec({ "git", "add", "." }, source_root)
  require_exec({ "git", "commit", "--quiet", "-m", "canonical qa fixture" }, source_root)
  local commit_sha = require_exec({ "git", "rev-parse", "HEAD" }, source_root):match("([0-9a-f]+)")
  local store = Store.new()
  local repository = {
    slug = "owner/canonical-qa",
    url = "https://example.invalid/generic/canonical-qa.git",
    commit_sha = commit_sha,
  }
  local trace_id = "trace-" .. run_id
  local dedup_key = run_id
  local origin = "http://127.0.0.1:" .. tostring(port)
  local base_url = origin .. "/health"
  local profile_ref = ref(artifact_root .. "/authorization/profile.json")
  local approval_ref = ref(artifact_root .. "/authorization/approval.json")
  local validation_ref = ref(artifact_root .. "/authorization/profile-validation.json")
  local authority = { kind = "host-policy", ref = "fixtures/canonical-qa" }
  local evidence = { kind = "signed-attestation", ref = "fixtures/canonical-qa-approval" }
  local profile = {
    schema = project_profile.schemas.profile,
    revision = "canonical-qa-profile-v1",
    repository = { url = repository.url, commit_sha = repository.commit_sha },
    working_directory = ".",
    commands = {
      install = { "npm", "ci", "--offline", "--ignore-scripts" },
      build = { "npm", "run", "build" },
      start = { "node", "server.js", tostring(port) },
      cleanup = { "node", "cleanup.js" },
    },
    application_listener_mode = project_profile.listener_mode,
    readiness_checks = { { type = "http", url = base_url, expected_status = 200 } },
    allowed_origins = { origin },
    mutation_policy = { mode = "read-only" },
    timeouts = {
      install_seconds = 20, build_seconds = 10, migrate_seconds = 5, seed_seconds = 5,
      start_seconds = 10, readiness_seconds = 10, cleanup_seconds = 10,
      total_seconds = 120, receipt_ttl_seconds = 120,
    },
    resource_budgets = {
      cpu_millis = 64000, memory_mb = 256, disk_mb = 128, processes = 4,
      network_requests = 32, output_bytes = 32768,
    },
  }
  local trusted = {
    source_ref = authority,
    policy_revision = "canonical-qa-policy-v1",
    verify = function(request)
      return {
        authenticated = true,
        approval_sha256 = request.approval_sha256,
        authority = copy(request.approval.authority),
        policy_revision = request.approval.policy_revision,
        evidence_ref = copy(request.approval.evidence_ref),
      }
    end,
  }
  local approval = {
    schema = project_profile.schemas.approval,
    approval_id = run_id .. "-approval",
    canonicalization = project_profile.canonicalization,
    profile_sha256 = project_profile.profile_sha256(profile, sha256_bytes),
    repository = { url = repository.url, commit_sha = repository.commit_sha },
    authority = authority,
    policy_revision = "canonical-qa-policy-v1",
    evidence_ref = evidence,
    issued_at = "2026-07-22T00:00:00Z",
    expires_at = "2026-07-22T01:00:00Z",
    max_uses = 1,
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  local authorization_claim
  local authorization_context = {
    now = "2026-07-22T00:10:00Z",
    sha256 = sha256_bytes,
    trusted_authorities = { trusted },
    approval_ref = approval_ref,
    replay_guard = function(value)
      if authorization_claim ~= nil and not equal(authorization_claim, value) then return { claimed = false } end
      authorization_claim = authorization_claim or copy(value)
      return { claimed = true, claim_id = run_id .. "-profile-claim" }
    end,
  }
  local validation_receipt = project_profile.issue_validation_receipt(profile, approval, {
    now = authorization_context.now,
    sha256 = sha256_bytes,
    trusted_authorities = authorization_context.trusted_authorities,
    approval_ref = approval_ref,
  })
  assert(store:write(profile_ref.ref, profile))
  assert(store:write(approval_ref.ref, approval))
  assert(store:write(validation_ref.ref, validation_receipt))

  local catalog_ref = artifact_root .. "/execution/case-catalog.json"
  local catalog = {
    schema = execution.schemas.case_catalog,
    repository = { url = repository.url, commit_sha = repository.commit_sha },
    cases = {
      {
        design_case_id = "service:reachability",
        case_id = "cli-version",
        kind = "cli",
        argv = { "node", "cli.js", "--version" },
        timeout_seconds = 10,
        assertions = { { type = "exit-code", expected = 0 } },
      },
      {
        design_case_id = "service:page-load",
        case_id = "health",
        kind = "http",
        request = { method = "GET", url = base_url, headers = {} },
        timeout_seconds = 10,
        assertions = {
          { type = "status-code", expected = 200 },
          { type = "body-contains", expected = "healthy" },
        },
      },
    },
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  assert(store:write(catalog_ref, catalog))
  local preauthorization_ref = artifact_root .. "/execution/preauthorization.json"
  local preauthorization = {
    schema = execution.schemas.preauthorization,
    authorization_id = run_id .. "-execution-authorization",
    repository = { url = repository.url, commit_sha = repository.commit_sha },
    profile_sha256 = approval.profile_sha256,
    case_catalog_sha256 = store:digest(catalog_ref),
    capabilities = {
      cli = { { argv_prefix = { "node", "cli.js" } } },
      http = { { origin = origin, methods = { "GET" }, path_prefixes = { "/health" } } },
    },
    authority = { kind = "host-policy", ref = "fixtures/canonical-qa-execution" },
    policy_revision = "canonical-qa-execution-v1",
    evidence_ref = { kind = "signed-attestation", ref = "fixtures/canonical-qa-execution-approval" },
    issued_at = "2026-07-22T00:00:00Z",
    expires_at = "2026-07-22T01:00:00Z",
    max_uses = 1,
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  assert(store:write(preauthorization_ref, preauthorization))

  local request = {
    schema = workflow_qa.schemas.request,
    issue = { repository = repository.slug, number = 101, state = "open", labels = { "fkst-qa" } },
    run_id = run_id,
    repository = copy(repository),
    artifact_root = artifact_root,
    state_ref = artifact_root .. "/workflow-state.json",
    proposed_cases = {
      {
        id = "seed-health", module_id = "service", priority = "P0", title = "Health endpoint",
        objective = "Verify the canonical fixture health endpoint.", case_kind = "api",
        actions = { { action = "http", target = "/health", expected = "HTTP 200" } },
        expected_observable = "The canonical fixture reports healthy.",
        coverage_subject_ids = { "REQ-HEALTH" }, review_status = "executable",
      },
    },
    environment_start = {
      schema = "environment-factory.start.v1",
      operation_id = run_id,
      repository = { url = repository.url, commit_sha = repository.commit_sha },
      profile_ref = profile_ref,
      approval_ref = approval_ref,
      validation_receipt_ref = validation_ref,
      operation_state_ref = ref(artifact_root .. "/environment/operation-state.json"),
      artifact_root = artifact_root .. "/environment",
      base_url = base_url,
      runtime_ports = { { name = "application", port = port } },
      sessions = { { role = "browser", cdp_url = "http://127.0.0.1:" .. tostring(cdp_port) } },
      trace_id = trace_id,
      dedup_key = dedup_key,
    },
    analysis_request = {
      schema = "testing-design.analysis-request.v1",
      repository = {
        url = repository.url,
        commit_sha = repository.commit_sha,
        baseline_commit_sha = string.rep("0", 40),
        workspace_ref = { kind = "workspace", ref = run_id .. "-workspace" },
        approval_ref = validation_ref,
        approval_sha256 = store:digest(validation_ref.ref),
      },
      inputs = {},
      artifact_root = artifact_root .. "/analysis",
      source_ref = { kind = "workflow-qa", ref = run_id },
      trace_id = trace_id,
      dedup_key = dedup_key,
    },
    design_module_start = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "service",
      backend = "fkst-native",
      no_browser = false,
      dry_run = false,
      artifact_root = artifact_root .. "/design",
      source_ref = { kind = "workflow-qa", ref = run_id },
      trace_id = trace_id,
      dedup_key = dedup_key,
      ui_loop = {
        allowed_origins = { origin },
        mutation_policy = "read-only",
        cdp_readiness_ref = "canonical-cdp-ready",
      },
      module_discovery = {
        schema = "testing-runner.module-discovery.v1",
        observations = {
          {
            id = "service", name = "Canonical Service", entry_url = base_url,
            visible_label = "Canonical Service", discovery_source = "navigation", confidence = "high",
            evidence_pointer = artifact_root .. "/design/evidence/service.json",
          },
        },
        limitations = { "The canonical fixture exposes one local service surface." },
      },
    },
    structured_execution = {
      artifact_root = artifact_root .. "/execution",
      preauthorization_ref = preauthorization_ref,
      preauthorization_sha256 = store:digest(preauthorization_ref),
      case_catalog_ref = catalog_ref,
      case_catalog_sha256 = store:digest(catalog_ref),
      structured_plan_ref = artifact_root .. "/execution/structured-plan.json",
      grant_ref = artifact_root .. "/execution/execution-grant.json",
    },
    publication = {
      ledger_ref = artifact_root .. "/run-ledger.json",
      defect_ledger_ref = artifact_root .. "/execution/defect-ledger.json",
      defect_receipt_ref = artifact_root .. "/execution/defect-receipt.json",
      issue_drafts_ref = artifact_root .. "/execution/issue-drafts.json",
      aggregate_report_ref = artifact_root .. "/aggregate-report.json",
      terminal_summary_ref = artifact_root .. "/terminal-summary.json",
    },
    terminal_policy = { mode = "host" },
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  workflow_qa.validate_request(request)

  local context = setmetatable({
    port = port,
    cdp_port = cdp_port,
    origin = origin,
    base_url = base_url,
    run_id = run_id,
    artifact_root = artifact_root,
    temp_root = temp_root,
    source_root = source_root,
    workspace_root = workspace_root,
    host_root = host_root,
    commit_sha = commit_sha,
    repository = repository,
    profile = profile,
    approval = approval,
    validation_receipt = validation_receipt,
    authorization_context = authorization_context,
    request = request,
    store = store,
    effects = {},
    effect_order = {},
    target_effects = {},
    publications = {},
    publication_count = 0,
    execution_claims = 0,
    preauthorization_claims = 0,
    terminal_records = 0,
  }, Context)
  context.environment_runtime = context:_environment_runtime()
  context.workflow_runtime = context:_workflow_runtime()
  context.module_loop_runtime = context:_module_loop_runtime()
  context.testing_design_runtime = context:_testing_design_runtime()
  context.structured_runtime = context:_structured_runtime()
  context.publication_runtime = context:_publication_runtime()
  context.generic_host_runtime = context:_generic_host_runtime()
  return context
end

M.copy = copy
M.equal = equal
M.sha256_bytes = sha256_bytes

return M
