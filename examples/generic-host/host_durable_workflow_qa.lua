local browser_readiness = require("contract.browser_readiness")
local execution = require("contract.structured_execution")
local json_codec = require("testing_runtime.json")
local Store = require("host_durable_store")

local M = {}

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

local nonce_sequence = 0

local function next_nonce()
  local temporary = assert(os.tmpname())
  os.remove(temporary)
  local basename = temporary:gsub("\\", "/"):match("([^/]+)$")
  if type(basename) ~= "string" or basename == "" then
    error("generic-host durable nonce basename is unavailable")
  end
  nonce_sequence = nonce_sequence + 1
  return basename .. "-" .. tostring(nonce_sequence), temporary
end

local function bounded_text(value, limit)
  local text = tostring(value or ""):gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
  return text:sub(1, limit or 1024)
end

local function safe_label(value)
  return tostring(value or "request"):gsub("[^A-Za-z0-9._-]", "-"):sub(1, 160)
end

local function direct_exec(argv, cwd)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local command = table.concat(rendered, " ")
  if cwd ~= nil then command = "cd " .. shell_quote(cwd) .. " && " .. command end
  local nonce, temporary = next_nonce()
  local stdout_path = temporary .. "-durable-host-stdout-" .. nonce
  local stderr_path = temporary .. "-durable-host-stderr-" .. nonce
  local ok, _, code = os.execute(command .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local result = {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = read_file(stdout_path) or "",
    stderr = read_file(stderr_path) or "",
  }
  os.remove(stdout_path)
  os.remove(stderr_path)
  return result
end

local function require_exec(argv, cwd)
  local result = direct_exec(argv, cwd)
  if result.exit_code ~= 0 then
    error("generic-host durable command failed: " .. tostring(argv[1])
      .. " exit=" .. tostring(result.exit_code) .. " stderr=" .. tostring(result.stderr), 0)
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

local function spawn_process(argv, cwd, root)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = root .. "/server.stdout"
  local stderr_path = root .. "/server.stderr"
  os.execute("mkdir -p " .. shell_quote(root))
  local command = "cd " .. shell_quote(cwd) .. " && " .. table.concat(rendered, " ")
    .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path) .. " & echo $!"
  local pid = tonumber(require_exec({ "sh", "-c", command }):match("(%d+)"))
  if pid == nil then error("generic-host durable fixture server pid unavailable") end
  write_file(root .. "/server.pid", tostring(pid) .. "\n")
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
  return json.decode(result.stdout)
end

local function runtime_cli(project_root)
  local candidates = {
    project_root .. "/examples/generic-host/bin/durable-host-store.js",
    project_root .. "/packages/generic-host/bin/durable-host-store.js",
  }
  for _, candidate in ipairs(candidates) do
    if read_file(candidate) ~= nil then return candidate end
  end
  error("generic-host durable runtime CLI is unavailable")
end

local function host_root(durable_root)
  if type(durable_root) ~= "string" or durable_root:sub(1, 1) ~= "/" then
    error("generic-host durable root must be absolute")
  end
  return durable_root .. "/generic-host"
end

local function run_root(durable_root, run_id)
  if type(run_id) ~= "string" or run_id:match("^[A-Za-z0-9._-]+$") == nil then
    error("generic-host durable run_id is invalid")
  end
  return host_root(durable_root) .. "/" .. run_id
end

local ArtifactStore = {}
ArtifactStore.__index = ArtifactStore

function ArtifactStore.new(records)
  return setmetatable({ records = records }, ArtifactStore)
end

function ArtifactStore:load(path)
  local artifact = self.records:read_artifact(path)
  if artifact == nil then return nil end
  local ok, value = pcall(json.decode, artifact.body)
  if not ok then value = artifact.body end
  return { value = value, raw = artifact.body, digest = artifact.digest }
end

function ArtifactStore:write(path, value)
  return self:write_raw(path, json_codec.encode(value) .. "\n")
end

function ArtifactStore:write_raw(path, body)
  return self.records:write_artifact(path, body).written == true
end

function ArtifactStore:digest(path)
  local artifact = self.records:read_artifact(path)
  return artifact and artifact.digest or nil
end

local Context = {}
Context.__index = Context

function Context:_key(value)
  return self.records:digest(json_codec.encode(value))
end

function Context:_effect(owner, effect_id, binding, fn)
  local key = owner .. "/effects/" .. self:_key(effect_id)
  local existing = self.records:read(key)
  if existing ~= nil then
    if not equal(existing.binding, binding) then
      error("generic-host durable effect binding differs: " .. tostring(effect_id))
    end
    return copy(existing.result)
  end
  local result = fn()
  local written = self.records:immutable(key, { binding = copy(binding), result = copy(result) })
  if written.written ~= true and written.replayed ~= true then
    error("generic-host durable effect commit conflict: " .. tostring(effect_id))
  end
  return copy(result)
end

function Context:_resource(kind, identity)
  return kind .. "/resources/" .. self:_key(identity)
end

function Context:_fixture_effect(name, payload, timeout_seconds)
  if type(self.project_root) ~= "string" or self.project_root:sub(1, 1) ~= "/"
    or self.project_root:find("/../", 1, true) or self.project_root:sub(-3) == "/.." then
    error("generic-host durable fixture runtime IO root is invalid", 0)
  end
  local io_root = self.project_root .. "/.testing/generic-host-fixture-runtime"
  local request_id = next_nonce()
  local stem = safe_label(name) .. "-" .. safe_label(self.run_id) .. "-" .. request_id
  local request_path = io_root .. "/" .. stem .. "-request.json"
  local response_path = io_root .. "/" .. stem .. "-response.json"
  if read_file(request_path) ~= nil or read_file(response_path) ~= nil then
    error("generic-host durable fixture effect found a stale runtime frame: " .. name, 0)
  end
  payload = copy(payload)
  payload.request_id = request_id
  payload.runtime_config_ref = { kind = "artifact", ref = ".testing/generic-host-runtime.json" }
  write_file(request_path, json_codec.encode(payload) .. "\n")
  local result = direct_exec({
    "env", "FKST_DURABLE_ROOT=" .. self.durable_root,
    "node", self.project_root .. "/packages/generic-host/bin/generic-host-runtime.js",
    "effect", "--name", name, "--request", request_path, "--response", response_path,
  }, self.project_root)
  local response_body = read_file(response_path)
  local decoded_ok, response = pcall(function() return json.decode(response_body) end)
  if decoded_ok and type(response) == "table" then
    if response.request_id == nil then
      error("generic-host durable fixture effect response request_id is missing: " .. name, 0)
    end
    if response.request_id ~= request_id then
      error("generic-host durable fixture effect response request_id differs: " .. name, 0)
    end
  end
  if result.exit_code ~= 0 then
    local message = "generic-host durable fixture effect failed: " .. name
      .. " exit=" .. tostring(result.exit_code)
      .. " stderr=" .. bounded_text(result.stderr, 1024)
    if decoded_ok and type(response) == "table" and type(response.error) == "string" then
      message = message .. " Host error=" .. bounded_text(response.error, 1024)
    end
    error(message, 0)
  end
  if not decoded_ok or type(response) ~= "table" or response.ok ~= true then
    error("generic-host durable fixture effect returned an invalid response: " .. name, 0)
  end
  return response.result
end

function Context:_environment_runtime()
  local context = self
  return {
    load_state = function(pointer)
      local record = context.records:read("environment-factory/state/" .. context:_key(pointer.ref))
      if record == nil then return nil end
      return { authenticated = true, state = copy(record.state), revision = record.version }
    end,
    save_state = function(pointer, state, expected)
      local saved = context.records:cas("environment-factory/state/" .. context:_key(pointer.ref), {
        version = expected + 1,
        state = copy(state),
      }, expected)
      if saved.saved ~= true then return { stale = true, revision = saved.version } end
      return { saved = true, revision = saved.version }
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
      local binding = {
        effect_id = request.effect_id,
        request_binding = copy(request.request_binding),
        runtime_ports = copy(request.runtime_ports),
      }
      return context:_effect("environment-factory", request.effect_id, binding, function()
        local snapshot = request.authorize()
        local cleanup_ref = { kind = "port-lease", ref = context.run_id .. "-ports" }
        local resource = context.records:immutable(context:_resource("environment-factory", cleanup_ref), {
          schema = "generic-host.environment-resource.v1",
          kind = "ports",
          operation_id = context.run_id,
          cleanup_ref = copy(cleanup_ref),
          runtime_ports = copy(request.runtime_ports),
          ownership_token = context.records:digest(context.run_id .. "\0ports\0" .. request.effect_id),
        })
        if resource.written ~= true and resource.replayed ~= true then
          error("generic-host durable port resource binding differs")
        end
        return {
          status = "passed",
          profile_snapshot = snapshot,
          cleanup_ref = cleanup_ref,
          runtime_ports = copy(request.runtime_ports),
          deadline_epoch_seconds = 1784685600,
          request_binding = copy(request.request_binding),
        }
      end)
    end,
    checkout = function(request)
      return context:_effect("environment-factory", request.effect_id, request, function()
        remove_tree(context.workspace_root, context.temp_root .. "/")
        require_exec({ "git", "clone", "--quiet", context.source_root, context.workspace_root })
        require_exec({ "git", "checkout", "--quiet", context.commit_sha }, context.workspace_root)
        local resolved = require_exec({ "git", "rev-parse", "HEAD" }, context.workspace_root):match("([0-9a-f]+)")
        if resolved ~= context.commit_sha then error("generic-host durable checkout resolved the wrong commit") end
        local workspace_ref = { kind = "workspace", ref = context.run_id .. "-workspace" }
        local cleanup_ref = { kind = "workspace-cleanup", ref = context.run_id .. "-workspace" }
        context:_fixture_effect("fixture-register-workspace", {
          run_id = context.run_id,
          operation_id = context.run_id,
          workspace_ref = workspace_ref,
          cleanup_ref = cleanup_ref,
          path = context.workspace_root,
          repository = copy(context.repository),
          artifact_root = context.artifact_root,
          trace_id = context.request.trace_id,
          dedup_key = context.request.dedup_key,
        })
        return {
          status = "passed",
          resolved_commit = resolved,
          workspace_ref = workspace_ref,
          cleanup_ref = cleanup_ref,
        }
      end)
    end,
    remaining_budget = function() return 120 end,
    create_readiness_attempt = function(request)
      return context:_effect("environment-factory", request.effect_id, request, function()
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
          status = "passed", attempt_id = "attempt-1", attempt_ref = { kind = "artifact", ref = path },
          attempt_sha256 = context.store:digest(path),
        }
      end)
    end,
    run_argv = function(request)
      return context:_effect("environment-factory", request.effect_id, request, function()
        local workspace_record = context.records:read(context:_resource("environment-factory", request.workspace_ref))
        if workspace_record == nil then error("generic-host durable workspace is unavailable") end
        if request.mode == "supervised" then
          local cleanup_ref = { kind = "process-cleanup", ref = context.run_id .. "-application" }
          return context:_fixture_effect("fixture-start-application", {
            run_id = context.run_id,
            operation_id = request.operation_id,
            effect_id = request.effect_id,
            argv = copy(request.argv),
            workspace_ref = copy(request.workspace_ref),
            cleanup_ref = cleanup_ref,
            runtime_ports = copy(request.runtime_ports),
            artifact_root = request.artifact_root,
            trace_id = request.trace_id,
            dedup_key = request.dedup_key,
          })
        end
        local result = direct_exec(request.argv, workspace_record.path)
        local outcome = { status = result.exit_code == 0 and "passed" or "blocked" }
        if request.requires_frozen_dependencies then outcome.frozen_dependencies_enforced = true end
        return outcome
      end)
    end,
    wait_readiness = function(request)
      return context:_effect("environment-factory", request.effect_id, request, function()
        for _, check in ipairs(request.checks or {}) do
          if check.type == "http" then
            if not wait_http(check.url, request.timeout_seconds) then return { status = "blocked" } end
          elseif check.type == "argv" then
            local workspace = context.records:read(context:_resource("environment-factory", request.workspace_ref))
            if workspace == nil or direct_exec(check.argv, workspace.path).exit_code ~= 0 then
              return { status = "blocked" }
            end
          else
            return { status = "blocked" }
          end
        end
        return { status = "ready" }
      end)
    end,
    cleanup = function(request)
      return context:_effect("environment-factory", request.effect_id, request, function()
        return context:_fixture_effect("cleanup", request, request.timeout_seconds)
      end)
    end,
    write_receipt = function(request)
      return context:_effect("environment-factory", request.effect_id, request, function()
        if context.store:write(request.receipt_ref.ref, request.receipt) ~= true then return { status = "blocked" } end
        return { status = "passed" }
      end)
    end,
  }
end

function Context:_workflow_runtime()
  local context = self
  local state_key = "workflow-qa/state/" .. context.run_id
  return {
    load_state = function(path)
      if path ~= context.request.state_ref then return nil end
      return copy(context.records:read(state_key))
    end,
    load_run = function(trace_id, dedup_key)
      local request = context.records:read("workflow-qa/requests/" .. context.run_id)
      if request ~= nil and request.trace_id == trace_id and request.dedup_key == dedup_key then return request end
    end,
    load_run_by_id = function(run_id)
      if run_id ~= context.run_id then return nil end
      return copy(context.records:read("workflow-qa/requests/" .. run_id))
    end,
    list_pending_runs = function(limit)
      local pending = {}
      for _, entry in ipairs(context.records:list("workflow-qa/requests")) do
        local request = entry.value
        local state = request and context.records:read("workflow-qa/state/" .. tostring(request.run_id)) or nil
        local terminal = request and context.records:read("generic-host/terminal/" .. tostring(request.run_id)) or nil
        if type(request) == "table" and type(state) == "table"
          and (state.phase ~= "terminal" or terminal == nil) then
          table.insert(pending, copy(request))
          if #pending >= limit then break end
        end
      end
      table.sort(pending, function(left, right) return left.run_id < right.run_id end)
      return pending
    end,
    save_state = function(path, value, expected)
      if path ~= context.request.state_ref then return false end
      return context.records:cas(state_key, copy(value), expected).saved == true
    end,
    load_artifact = function(path) return context.store:load(path) end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    artifact_digest = function(path) return context.store:digest(path) end,
  }
end

function Context:_module_loop_runtime()
  local context = self
  return {
    load_state = function(path) return copy(context.records:read("module-test-loop/state/" .. context:_key(path))) end,
    save_state = function(path, value, expected)
      return context.records:cas("module-test-loop/state/" .. context:_key(path), copy(value), expected).saved == true
    end,
    list_pending_states = function(limit)
      local out = {}
      for _, entry in ipairs(context.records:list("module-test-loop/state")) do
        if type(entry.value) == "table" and entry.value.phase ~= "terminal" then
          table.insert(out, entry.key)
          if #out >= limit then break end
        end
      end
      return out
    end,
    artifact_digest = function(path) return context.store:digest(path) end,
  }
end

function Context:_testing_design_runtime()
  local context = self
  return {
    analyze = function(request)
      local key = "testing-design/results/" .. context:_key({ request.trace_id, request.dedup_key })
      local existing = context.records:read(key)
      if existing ~= nil then local replay = copy(existing) replay.replayed = true return replay end
      local root = request.artifact_root
      local docs = {
        repository_analysis = {
          path = root .. "/repository-analysis.v1.json", schema = "testing-design.repository-analysis.v1",
          value = { schema = "testing-design.repository-analysis.v1", repository = copy(request.repository), modules = { "service" } },
        },
        requirements_index = {
          path = root .. "/requirements-index.v1.json", schema = "testing-design.requirements-index.v1",
          value = { schema = "testing-design.requirements-index.v1", requirements = { { id = "REQ-HEALTH", priority = "P0" } } },
        },
        traceability_seed = {
          path = root .. "/traceability-seed.v1.json", schema = "testing-design.traceability-seed.v1",
          value = { schema = "testing-design.traceability-seed.v1", links = { { requirement = "REQ-HEALTH", module = "service" } } },
        },
      }
      local refs = {}
      for name, doc in pairs(docs) do
        assert(context.store:write(doc.path, doc.value))
        refs[name] = {
          schema = "testing-design.artifact-reference.v1", artifact_schema = doc.schema,
          artifact_pointer = doc.path, artifact_digest = context.store:digest(doc.path),
        }
      end
      local analysis_key = context.records:digest(json_codec.encode(refs))
      local result = {
        status = "complete", replayed = false, analysis_key = analysis_key,
        context = {
          schema = "testing-design.context-reference.v1", analysis_key = analysis_key,
          repository_analysis = refs.repository_analysis, requirements_index = refs.requirements_index,
          traceability_seed = refs.traceability_seed,
        },
      }
      if context.records:immutable(key, result).written ~= true then error("generic-host durable analysis result conflict") end
      return copy(result)
    end,
  }
end

function Context:_structured_runtime()
  local context = self
  local function replay_key(grant_id) return "testing-runner/replay/" .. context:_key(grant_id) end
  return {
    load_artifact = function(path) return context.store:load(path) end,
    now = function(request)
      if request.artifact_root ~= context.request.structured_execution.artifact_root then
        error("generic-host durable structured runtime received a foreign artifact root")
      end
      return "2026-07-22T00:20:00Z"
    end,
    verify_grant = function(request)
      local grant = request.grant
      return {
        grant_sha256 = request.grant_sha256, authority = copy(grant.authority),
        policy_revision = grant.policy_revision, evidence_ref = copy(grant.evidence_ref),
      }
    end,
    replay_guard = function(request)
      local key = replay_key(request.grant_id)
      local claim_id = context.run_id .. "-execution-claim"
      local claimed = context.records:claim(key, {
        status = "claimed", claim_id = claim_id, binding = copy(request),
      })
      if claimed.claimed ~= true then return nil end
      local value = claimed.value
      if value.status == "completed" then
        return { status = "completed", result_ref = value.result_ref, result_sha256 = value.result_sha256 }
      end
      if claimed.replayed == true then return { status = "in-progress" } end
      return { status = "claimed", claim_id = claim_id }
    end,
    exec_argv = function(request)
      if request.operation_id ~= context.run_id
        or type(request.workspace_ref) ~= "table"
        or request.workspace_ref.ref ~= context.run_id .. "-workspace"
        or request.repository.commit_sha ~= context.commit_sha then
        error("generic-host durable structured CLI request is not bound to the ready workspace")
      end
      local workspace = context.records:read(context:_resource("environment-factory", request.workspace_ref))
      if workspace == nil then error("generic-host durable structured workspace is unavailable") end
      local result = direct_exec(request.argv, workspace.path)
      context.records:immutable("testing-runner/target-effects/" .. context:_key(request), {
        binding = copy(request), result = copy(result),
      })
      return result
    end,
    http_request = function(input)
      if input.operation_id ~= context.run_id or input.base_url ~= context.base_url
        or input.request.url ~= context.base_url then
        error("generic-host durable structured HTTP request is not bound to the ready environment")
      end
      local result = http_request(input.request, input.timeout_seconds)
      context.records:immutable("testing-runner/target-effects/" .. context:_key(input), {
        binding = copy(input), result = copy(result),
      })
      return result
    end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    load_result = function(request)
      local artifact = context.store:load(request.result_ref)
      if artifact == nil or (request.result_sha256 ~= nil and artifact.digest ~= request.result_sha256) then return nil end
      local value = artifact.value
      if value.operation_id ~= request.operation_id or value.environment_receipt_sha256 ~= request.environment_receipt_sha256
        or value.trace_id ~= request.trace_id or value.dedup_key ~= request.dedup_key then return nil end
      return {
        schema = "testing-runner.structured-execution-summary.v1", status = value.status,
        classification = value.classification, mode = "structured-api-cli",
        artifact_root = context.request.structured_execution.artifact_root,
        case_count = value.case_count, passed_count = value.passed_count, failed_count = value.failed_count,
        skipped_count = value.skipped_count, error_count = value.error_count,
        test_plan_path = value.test_plan_path, case_results_path = value.case_results_path,
        execution_path = value.execution_path, replayed = true,
      }
    end,
    complete_replay = function(request)
      local current
      for _, entry in ipairs(context.records:list("testing-runner/replay")) do
        if type(entry.value) == "table" and entry.value.claim_id == request.claim.claim_id then
          current = entry
          break
        end
      end
      if current == nil or current.value.status ~= "claimed" then return false end
      local binding = current.value.binding
      if binding.artifact_root ~= request.artifact_root or binding.operation_id ~= request.operation_id
        or binding.environment_receipt_sha256 ~= request.environment_receipt_sha256
        or not execution.same_repository(binding.repository, request.repository)
        or binding.trace_id ~= request.trace_id or binding.dedup_key ~= request.dedup_key then
        return false
      end
      local result_sha256 = context.store:digest(request.result_ref)
      if result_sha256 == nil then return false end
      local completion = copy(request)
      completion.claim = nil
      completion.result_sha256 = result_sha256
      return context.records:complete_replay(current.key, request.claim.claim_id, completion).completed == true
    end,
  }
end

function Context:_publication_runtime()
  local context = self
  return {
    load_ledger = function(path) return copy(context.records:read("test-publication/ledgers/" .. context:_key(path))) end,
    save_ledger = function(path, value, expected)
      return context.records:cas("test-publication/ledgers/" .. context:_key(path), copy(value), expected).saved == true
    end,
    publish_artifact = function(request)
      local key = "test-publication/effects/" .. context:_key(request)
      local existing = context.records:read(key)
      if existing ~= nil then
        if not equal(existing.binding, request) then error("generic-host durable publication binding differs") end
        return copy(existing.result)
      end
      local value
      if request.channel == "filesystem-dry-run-v1" then
        local receipt_ref = context.artifact_root .. "/published/" .. request.stage .. "-"
          .. tostring(request.attempt) .. "-materialization.json"
        local receipt = {
          schema = "test-publication.qa-materialization-receipt.v1",
          status = "materialized", channel = request.channel, run_id = request.run_id,
          stage = request.stage, attempt = request.attempt, artifact_ref = request.artifact_ref,
          digest = request.digest, source_commit = request.repository.commit_sha,
          receipt_ref = receipt_ref, trace_id = request.trace_id, dedup_key = request.dedup_key,
        }
        assert(context.store:write(receipt_ref, receipt))
        value = {
          status = "materialized", artifact_ref = request.artifact_ref, digest = request.digest,
          source_commit = request.repository.commit_sha, receipt_ref = receipt_ref,
          receipt_sha256 = context.store:digest(receipt_ref),
        }
      else
        value = {
          status = "published",
          remote_url = "https://github.com/" .. request.repository.slug .. "/blob/" .. request.repository.commit_sha
            .. "/qa/" .. request.stage .. "-" .. tostring(request.attempt) .. ".json",
          digest = request.digest,
          source_commit = request.repository.commit_sha,
          receipt_ref = context.artifact_root .. "/published/" .. request.stage .. "-" .. tostring(request.attempt) .. ".json",
        }
      end
      local stored = context.records:immutable(key, { binding = copy(request), result = copy(value) })
      if stored.written ~= true and stored.replayed ~= true then
        error("generic-host durable publication commit conflict")
      end
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
  return {
    load_artifact = function(path) return context.store:load(path) end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    artifact_digest = function(path) return context.store:digest(path) end,
    claim_preauthorization = function(value)
      local claimed = context.records:claim("generic-host/preauthorization/" .. context:_key(value.authorization_id), {
        binding = copy(value), claim_id = context.run_id .. "-preauthorization",
      })
      if claimed.claimed ~= true then return { status = "blocked" } end
      return {
        status = "claimed", claim_id = claimed.value.claim_id, replayed = claimed.replayed == true,
      }
    end,
    grant_values = function()
      return {
        grant_id = context.run_id .. "-grant",
        evidence_ref = { kind = "signed-attestation", ref = context.run_id .. "-execution-grant" },
        issued_at = "2026-07-22T00:15:00Z", expires_at = "2026-07-22T00:45:00Z",
        now = "2026-07-22T00:20:00Z",
      }
    end,
    record_terminal = function(value)
      local result = context.records:immutable("generic-host/terminal/" .. context.run_id, copy(value))
      return result.written == true or result.replayed == true
    end,
  }
end

function Context:next_comment_id()
  local key = "test-publication/comment-sequence"
  local current = self.records:read(key)
  local version = current and current.version or 0
  local value = current and current.value or 10000
  local saved = self.records:cas(key, { version = version + 1, value = value + 1 }, version)
  if saved.saved ~= true then error("generic-host durable comment sequence conflict") end
  return saved.value.value
end

function Context:after_replay_complete(outcome, request)
  if outcome.status == "blocked" then return end
  local claims = self.records:list("testing-runner/replay")
  if #claims ~= 1 or claims[1].value.status ~= "completed" then
    error("generic-host durable replay claim is not completed at the crash barrier")
  end
  if self.store:load(outcome.execution_path) == nil then
    error("generic-host durable execution result is unavailable at the crash barrier")
  end
  if outcome.replayed == true then
    local result = self.records:immutable("generic-host/recovery/execution", {
      request = copy(request), replayed = true,
    })
    if result.written ~= true and result.replayed ~= true then error("generic-host recovery observation conflict") end
    return
  end
  if self.completed_replay_failpoint == nil then return end
  if self.records:read("generic-host/barriers/post-replay-complete") ~= nil then return end
  local fifo = self.root .. "/post-replay-complete.fifo"
  os.remove(fifo)
  require_exec({ "mkfifo", fifo })
  local barrier = self.records:immutable("generic-host/barriers/post-replay-complete", {
    run_id = self.run_id,
    result_ref = outcome.execution_path,
    result_sha256 = self.store:digest(outcome.execution_path),
    replay_status = claims[1].value.status,
  })
  if barrier.written ~= true then return end
  local handle = io.open(fifo, "r")
  if handle ~= nil then handle:read("*l") handle:close() end
end

function Context:terminal_record()
  return self.records:read("generic-host/terminal/" .. self.run_id)
end

local function authorization_context(config, records)
  local authority = copy(config.approval.authority)
  local policy_revision = config.approval.policy_revision
  local evidence_ref = copy(config.approval.evidence_ref)
  local trusted = {
    source_ref = copy(authority),
    policy_revision = policy_revision,
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
  return {
    now = config.authorization_now,
    sha256 = function(body) return records:digest(body) end,
    trusted_authorities = { trusted },
    approval_ref = copy(config.authorization_approval_ref),
    replay_guard = function(value)
      local claimed = records:claim("generic-host/profile-approval/" .. config.run_id, {
        binding = copy(value), claim_id = config.run_id .. "-profile-claim",
      })
      return { claimed = claimed.claimed == true, claim_id = claimed.value and claimed.value.claim_id }
    end,
  }
end

local function build_context(config, durable_root)
  local root = run_root(durable_root, config.run_id)
  local records = Store.new(root, runtime_cli(config.project_root))
  local context = setmetatable(copy(config), Context)
  context.root = root
  context.durable_root = durable_root
  context.records = records
  context.store = ArtifactStore.new(records)
  context.authorization_context = authorization_context(config, records)
  context.environment_runtime = context:_environment_runtime()
  context.workflow_runtime = context:_workflow_runtime()
  context.module_loop_runtime = context:_module_loop_runtime()
  context.testing_design_runtime = context:_testing_design_runtime()
  context.structured_runtime = context:_structured_runtime()
  context.publication_runtime = context:_publication_runtime()
  context.generic_host_runtime = context:_generic_host_runtime()
  return context
end

function M.initialize(context, durable_root)
  local root = run_root(durable_root, context.run_id)
  local records = Store.new(root, runtime_cli(context.project_root))
  local config = {
    schema = "generic-host.durable-workflow-qa.v1",
    project_root = context.project_root,
    port = context.port,
    cdp_port = context.cdp_port,
    origin = context.origin,
    base_url = context.base_url,
    run_id = context.run_id,
    artifact_root = context.artifact_root,
    temp_root = context.temp_root,
    source_root = context.source_root,
    workspace_root = context.workspace_root,
    host_root = context.host_root,
    commit_sha = context.commit_sha,
    repository = copy(context.repository),
    profile = copy(context.profile),
    approval = copy(context.approval),
    validation_receipt = copy(context.validation_receipt),
    authorization_now = context.authorization_context.now,
    authorization_approval_ref = copy(context.authorization_context.approval_ref),
    completed_replay_failpoint = copy(context.completed_replay_failpoint),
    request = copy(context.request),
  }
  local stored = records:immutable("generic-host/config", config)
  if stored.written ~= true and stored.replayed ~= true then error("generic-host durable config binding differs") end
  local initial_paths = {
    context.request.environment_start.profile_ref.ref,
    context.request.environment_start.approval_ref.ref,
    context.request.environment_start.validation_receipt_ref.ref,
    context.request.structured_execution.case_catalog_ref,
    context.request.structured_execution.preauthorization_ref,
  }
  for _, path in ipairs(initial_paths) do
    local artifact = context.store:load(path)
    if artifact == nil or records:write_artifact(path, artifact.raw).written ~= true then
      error("generic-host durable initial artifact write failed: " .. tostring(path))
    end
  end
  local request = records:immutable("workflow-qa/requests/" .. context.run_id, copy(context.request))
  if request.written ~= true and request.replayed ~= true then error("generic-host durable run request binding differs") end
  local index = Store.new(host_root(durable_root), runtime_cli(context.project_root))
  local indexed = index:immutable("runs/" .. context.run_id, {
    schema = "generic-host.durable-workflow-qa-index.v1",
    project_root = context.project_root,
    run_id = context.run_id,
  })
  if indexed.written ~= true and indexed.replayed ~= true then
    error("generic-host durable run index binding differs")
  end
  context.durable_root = durable_root
  context.durable_run_root = root
  return context
end

function M.load(project_root, durable_root, run_id)
  local root = run_root(durable_root, run_id)
  local records = Store.new(root, runtime_cli(project_root))
  local config = records:read("generic-host/config")
  if type(config) ~= "table" or config.schema ~= "generic-host.durable-workflow-qa.v1"
    or config.project_root ~= project_root or config.run_id ~= run_id then
    error("generic-host durable config is unavailable or foreign")
  end
  return build_context(config, durable_root)
end

function M.list_indexed_runs(project_root, durable_root, limit)
  limit = tonumber(limit) or 100
  if limit < 1 or limit > 1000 or limit % 1 ~= 0 then
    error("generic-host durable indexed run limit is invalid")
  end
  local index = Store.new(host_root(durable_root), runtime_cli(project_root))
  local indexed = {}
  for _, entry in ipairs(index:list("runs")) do
    local run = entry.value
    if type(run) == "table" and run.schema == "generic-host.durable-workflow-qa-index.v1"
      and run.project_root == project_root and type(run.run_id) == "string" then
      table.insert(indexed, copy(run))
    end
  end
  table.sort(indexed, function(left, right) return left.run_id < right.run_id end)
  while #indexed > limit do table.remove(indexed) end
  return indexed
end

function M.list_pending(project_root, durable_root, limit)
  limit = tonumber(limit) or 100
  if limit < 1 or limit > 1000 or limit % 1 ~= 0 then
    error("generic-host durable pending run limit is invalid")
  end
  local pending = {}
  for _, run in ipairs(M.list_indexed_runs(project_root, durable_root, 1000)) do
    local context = M.load(project_root, durable_root, run.run_id)
    local state = context.workflow_runtime.load_state(context.request.state_ref)
    if state == nil or (type(state) == "table"
      and (state.phase ~= "terminal" or context:terminal_record() == nil)) then
      table.insert(pending, context)
      if #pending >= limit then break end
    end
  end
  return pending
end

M.copy = copy
M.equal = equal
M.run_root = run_root

return M
