local browser_readiness = require("contract.browser_readiness")
local execution = require("contract.structured_execution")
local environment_factory = require("contract.environment_factory")
local json_codec = require("testing_runtime.json")
local project_profile = require("contract.project_profile")
local ai_design_loop = require("testing_ai.module_ai_design_loop")
local lineage_projection = require("testing_runtime.authorization_lineage_projection")
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

local design_input_fields = { "coverage_scope_ref", "deterministic_cases_ref" }

local function design_input_materialization_error(message)
  error("generic-host durable design input materialization failed: " .. message, 0)
end

local function design_inputs(request)
  local design_module_start = type(request) == "table" and request.design_module_start or nil
  local design_request = type(design_module_start) == "table"
    and design_module_start.ai_design_loop_request or nil
  if design_request == nil then return {} end
  if type(design_request) ~= "table" then
    design_input_materialization_error("ai_design_loop_request must be a table")
  end
  local inputs = {}
  for _, field in ipairs(design_input_fields) do
    local reference = design_request[field]
    local ok, err = pcall(ai_design_loop.validate_artifact_reference, reference)
    if not ok then
      design_input_materialization_error(field .. " reference is invalid: " .. bounded_text(err))
    end
    table.insert(inputs, { field = field, reference = reference })
  end
  return inputs
end

local function verify_design_input(project_root, input)
  local path = input.reference.artifact_pointer
  local body = read_file(project_root .. "/" .. path)
  if body == nil then design_input_materialization_error(input.field .. " is missing: " .. path) end
  local ok, document = pcall(json.decode, body)
  if not ok or type(document) ~= "table" then
    design_input_materialization_error(input.field .. " is not a JSON document: " .. path)
  end
  if ai_design_loop.document_digest(document) ~= input.reference.artifact_digest then
    design_input_materialization_error(input.field .. " digest mismatch: " .. path)
  end
end

local function require_design_input_sources(context, inputs)
  for _, input in ipairs(inputs) do
    local path = input.reference.artifact_pointer
    if context.store:load(path) == nil then
      design_input_materialization_error(input.field .. " is missing: " .. path)
    end
  end
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
    "let body='';res.setEncoding('utf8');res.on('data',c=>body+=c);res.on('end',()=>process.stdout.write(JSON.stringify({status:res.statusCode,headers:res.headers,body})));",
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

local function bound_artifact(store, path, expected_digest, label)
  local artifact = store:load(path)
  if artifact == nil or type(artifact.value) ~= "table"
    or (expected_digest ~= nil and artifact.digest ~= expected_digest) then
    error("generic-host durable " .. label .. " artifact binding differs")
  end
  return artifact
end

local lineage_envelope_fields = {
  repository = true,
  run_id = true,
  trace_id = true,
  dedup_key = true,
}

local function receipt_fields(source)
  local fields = {}
  for key, value in pairs(source) do
    if lineage_envelope_fields[key] ~= true then fields[key] = copy(value) end
  end
  return fields
end

local function expected_profile_replay_binding(config)
  return {
    approval_id = config.approval.approval_id,
    approval_sha256 = config.validation_receipt.approval_sha256,
    profile_sha256 = config.validation_receipt.profile_sha256,
    repository = copy(config.profile.repository),
    trace_id = config.validation_receipt.trace_id,
    dedup_key = config.validation_receipt.dedup_key,
    max_uses = config.approval.max_uses,
  }
end

local function profile_claim_receipt(config, store, projector, durable_claim)
  local claimed_at = type(durable_claim) == "table"
    and (durable_claim.claimed_at or config.authorization_now) or nil
  if type(durable_claim) ~= "table"
    or not equal(durable_claim.binding, expected_profile_replay_binding(config))
    or type(durable_claim.claim_id) ~= "string" or durable_claim.claim_id == ""
    or type(claimed_at) ~= "string" or claimed_at == "" then
    error("generic-host durable environment authorization approval claim is unavailable")
  end
  local start = config.request.environment_start
  local profile = bound_artifact(store, start.profile_ref.ref, nil, "profile")
  local approval = bound_artifact(store, start.approval_ref.ref, nil, "profile approval")
  local validation = bound_artifact(store, start.validation_receipt_ref.ref, nil, "profile validation")
  if profile.value.revision ~= config.validation_receipt.profile_revision
    or approval.value.approval_id ~= config.validation_receipt.approval_id
    or validation.value.profile_sha256 ~= config.validation_receipt.profile_sha256
    or validation.value.approval_sha256 ~= config.validation_receipt.approval_sha256 then
    error("generic-host durable profile claim source artifacts differ")
  end
  local fingerprint = projector:fingerprint("project-profile-approval-claim", durable_claim.claim_id)
  local source = {
      repository = { url = config.repository.url, commit_sha = config.repository.commit_sha },
      run_id = config.run_id,
      trace_id = config.request.trace_id,
      dedup_key = config.request.dedup_key,
      profile_source_ref = copy(config.profile_source_ref),
      profile_artifact_ref = start.profile_ref.ref,
      profile_artifact_sha256 = profile.digest,
      profile_sha256 = validation.value.profile_sha256,
      profile_revision = profile.value.revision,
      approval_artifact_ref = start.approval_ref.ref,
      approval_artifact_sha256 = approval.digest,
      approval_id = approval.value.approval_id,
      approval_sha256 = validation.value.approval_sha256,
      approval_authority = copy(approval.value.authority),
      policy_revision = approval.value.policy_revision,
      evidence_ref = copy(approval.value.evidence_ref),
      validation_receipt_ref = start.validation_receipt_ref.ref,
      validation_receipt_sha256 = validation.digest,
      claim_fingerprint_sha256 = fingerprint,
      claimed_at = claimed_at,
    }
  return projector:write_receipt("profile_claim", "profile-claim-" .. fingerprint:sub(1, 32),
    claimed_at, receipt_fields(source), source)
end

local canonical_execution_fields = {
  "case_result_set_path", "case_result_set_artifact_sha256",
  "evidence_manifest_path", "evidence_manifest_artifact_sha256",
}

local function valid_digest(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function structured_execution_artifacts(context, result_ref)
  local execution_artifact = context.store:load(result_ref)
  if execution_artifact == nil or type(execution_artifact.value) ~= "table" then return nil end
  local execution_value = execution_artifact.value
  local present = 0
  for _, field in ipairs(canonical_execution_fields) do
    if execution_value[field] ~= nil then present = present + 1 end
  end
  if present ~= 0 and present ~= #canonical_execution_fields then
    error("generic-host durable canonical execution artifact fields must be all-or-none")
  end
  if present == 0 then return execution_artifact, nil end

  local root = context.request.structured_execution.artifact_root
  if execution_value.test_plan_path ~= root .. "/test-plan.json"
    or not valid_digest(execution_value.plan_sha256)
    or execution_value.case_result_set_path ~= root .. "/case-result-set.json"
    or execution_value.evidence_manifest_path ~= root .. "/evidence-manifest.json"
    or not valid_digest(execution_value.case_result_set_artifact_sha256)
    or not valid_digest(execution_value.evidence_manifest_artifact_sha256) then
    error("generic-host durable canonical execution artifact binding is invalid")
  end
  local plan = context.store:load(execution_value.test_plan_path)
  local result_set = context.store:load(execution_value.case_result_set_path)
  local manifest = context.store:load(execution_value.evidence_manifest_path)
  if plan == nil or plan.digest ~= execution_value.plan_sha256
    or result_set == nil or result_set.digest ~= execution_value.case_result_set_artifact_sha256
    or manifest == nil or manifest.digest ~= execution_value.evidence_manifest_artifact_sha256
    or type(result_set.value) ~= "table" or type(manifest.value) ~= "table"
    or type(result_set.value.plan_ref) ~= "table" or result_set.value.plan_ref.kind ~= "artifact"
    or result_set.value.plan_ref.ref ~= execution_value.test_plan_path
    or result_set.value.plan_sha256 ~= execution_value.plan_sha256
    or type(manifest.value.plan_ref) ~= "table" or manifest.value.plan_ref.kind ~= "artifact"
    or manifest.value.plan_ref.ref ~= execution_value.test_plan_path
    or manifest.value.plan_sha256 ~= execution_value.plan_sha256 then
    error("generic-host durable canonical execution artifact digest mismatch")
  end
  return execution_artifact, {
    test_plan = plan,
    case_result_set = result_set,
    evidence_manifest = manifest,
  }
end

local function durable_execution_claim(context, required_status)
  local entries = context.records:list("testing-runner/replay")
  if #entries ~= 1 or type(entries[1].value) ~= "table"
    or type(entries[1].value.binding) ~= "table"
    or (required_status ~= nil and entries[1].value.status ~= required_status) then
    error("generic-host durable execution claim is unavailable")
  end
  return entries[1].value
end

local function execution_plan_matches_claim(execution_artifact, durable_claim)
  local value = execution_artifact and execution_artifact.value or nil
  local binding = durable_claim and durable_claim.binding or nil
  return type(value) == "table" and type(binding) == "table"
    and valid_digest(value.plan_sha256) and valid_digest(binding.plan_sha256)
    and value.plan_sha256 == binding.plan_sha256
end

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

local function lineage_source(context, fields)
  local source = {
    repository = { url = context.repository.url, commit_sha = context.repository.commit_sha },
    run_id = context.run_id,
    trace_id = context.request.trace_id,
    dedup_key = context.request.dedup_key,
  }
  for key, value in pairs(fields) do source[key] = copy(value) end
  return source
end

local function legacy_preauthorization_binding(request)
  return {
    authorization_id = request.authorization_id,
    preauthorization_sha256 = request.preauthorization_sha256,
    repository = copy(request.repository),
    plan_sha256 = request.plan_sha256,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

local function canonical_preauthorization_binding(request)
  return {
    authorization_id = request.authorization_id,
    preauthorization_ref = request.preauthorization_ref,
    preauthorization_sha256 = request.preauthorization_sha256,
    repository = copy(request.repository),
    plan_ref = request.plan_ref,
    plan_sha256 = request.plan_sha256,
    environment_receipt_ref = request.environment_receipt_ref,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

local function compatible_stored_preauthorization_binding(stored)
  if type(stored) ~= "table" or stored.runtime_config_ref == nil then return stored end
  if not equal(stored.runtime_config_ref, {
    kind = "artifact", ref = ".testing/generic-host-runtime.json",
  }) then return stored end
  local normalized = copy(stored)
  normalized.runtime_config_ref = nil
  return normalized
end

local function trusted_preauthorization_refs(context)
  return {
    preauthorization_ref = context.request.structured_execution.preauthorization_ref,
    plan_ref = context.request.structured_execution.structured_plan_ref,
    environment_receipt_ref = context.request.environment_start.artifact_root
      .. "/environment-receipt-ready.json",
  }
end

local function preauthorization_binding_matches(stored, request, trusted_refs)
  if type(trusted_refs) ~= "table"
    or request.preauthorization_ref ~= trusted_refs.preauthorization_ref
    or request.plan_ref ~= trusted_refs.plan_ref
    or request.environment_receipt_ref ~= trusted_refs.environment_receipt_ref then
    return false
  end
  local normalized = compatible_stored_preauthorization_binding(stored)
  return equal(normalized, canonical_preauthorization_binding(request))
    or equal(normalized, legacy_preauthorization_binding(request))
end

local function preauthorization_request(preauthorization, request)
  return {
    authorization_id = preauthorization.value.authorization_id,
    preauthorization_ref = request.preauthorization_ref,
    preauthorization_sha256 = preauthorization.digest,
    repository = copy(request.repository),
    plan_ref = request.plan_ref,
    plan_sha256 = request.plan_sha256,
    environment_receipt_ref = request.environment_receipt_ref,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

function Context:_private_claim_id(domain)
  local nonce = next_nonce()
  return "private-claim-" .. self.records:digest(
    self.lineage_projection_secret .. "\0" .. domain .. "\0" .. nonce)
end

function Context:_persist_profile_claim()
  local durable_claim = self.records:read("generic-host/profile-approval/" .. self.run_id)
  if type(durable_claim) ~= "table" then
    error("generic-host durable Profile claim is unavailable")
  end
  return profile_claim_receipt(self, self.store, self.lineage, durable_claim)
end

function Context:_persist_preauthorization_claim(request, durable_claim)
  if type(durable_claim) ~= "table" then
    error("generic-host durable preauthorization claim binding differs")
  end
  local claimed_at = durable_claim.claimed_at or self.execution_authorization_now
  if not preauthorization_binding_matches(
    durable_claim.binding, request, trusted_preauthorization_refs(self))
    or type(durable_claim.claim_id) ~= "string" or type(claimed_at) ~= "string" then
    error("generic-host durable preauthorization claim binding differs")
  end
  local profile_receipt = self:_persist_profile_claim()
  local preauthorization = bound_artifact(self.store, request.preauthorization_ref,
    request.preauthorization_sha256, "preauthorization")
  local catalog_ref = self.request.structured_execution.case_catalog_ref
  local catalog = bound_artifact(self.store, catalog_ref,
    self.request.structured_execution.case_catalog_sha256, "case catalog")
  local plan = bound_artifact(self.store, request.plan_ref, request.plan_sha256, "structured plan")
  local environment = bound_artifact(self.store, request.environment_receipt_ref,
    request.environment_receipt_sha256, "environment receipt")
  if preauthorization.value.authorization_id ~= request.authorization_id
    or preauthorization.value.profile_sha256 ~= profile_receipt.value.profile_sha256
    or preauthorization.value.case_catalog_sha256 ~= catalog.digest
    or plan.value.environment_receipt_sha256 ~= environment.digest then
    error("generic-host durable preauthorization lineage source differs")
  end
  local fingerprint = self.lineage:fingerprint("structured-preauthorization-claim", durable_claim.claim_id)
  local source = lineage_source(self, {
      profile_claim_receipt_ref = profile_receipt.ref,
      profile_claim_receipt_sha256 = profile_receipt.sha256,
      preauthorization_ref = request.preauthorization_ref,
      preauthorization_sha256 = preauthorization.digest,
      authorization_id = preauthorization.value.authorization_id,
      profile_sha256 = preauthorization.value.profile_sha256,
      case_catalog_ref = catalog_ref,
      case_catalog_sha256 = catalog.digest,
      plan_ref = request.plan_ref,
      plan_sha256 = plan.digest,
      environment_receipt_ref = request.environment_receipt_ref,
      environment_receipt_sha256 = environment.digest,
      authority = copy(preauthorization.value.authority),
      policy_revision = preauthorization.value.policy_revision,
      evidence_ref = copy(preauthorization.value.evidence_ref),
      claim_fingerprint_sha256 = fingerprint,
      claimed_at = claimed_at,
    })
  return self.lineage:write_receipt("preauthorization_claim",
    "preauthorization-claim-" .. fingerprint:sub(1, 32), claimed_at,
    receipt_fields(source), source)
end

local function execution_grant_values(context)
  return {
    grant_id = context.run_id .. "-grant",
    evidence_ref = { kind = "signed-attestation", ref = context.run_id .. "-execution-grant" },
    issued_at = "2026-07-22T00:15:00Z",
    expires_at = "2026-07-22T00:45:00Z",
    now = "2026-07-22T00:20:00Z",
  }
end

function Context:_persist_grant_verification(request)
  local preauthorization = bound_artifact(self.store, request.preauthorization_ref,
    request.preauthorization_sha256, "preauthorization")
  local durable_claim = self.records:read(
    "generic-host/preauthorization/" .. self:_key(preauthorization.value.authorization_id))
  if type(durable_claim) ~= "table" then
    error("generic-host durable Preauthorization claim is unavailable")
  end
  local grant = bound_artifact(self.store, request.grant_ref, request.grant_sha256, "execution grant")
  local plan = bound_artifact(self.store, request.plan_ref, request.plan_sha256, "structured plan")
  local environment = bound_artifact(self.store, request.environment_receipt_ref,
    request.environment_receipt_sha256, "environment receipt")
  if grant.value.parent_authorization_sha256 ~= preauthorization.digest
    or grant.value.plan_sha256 ~= plan.digest
    or grant.value.environment_receipt_sha256 ~= environment.digest
    or not execution.same_repository(grant.value.repository, request.repository) then
    error("generic-host durable grant verification source differs")
  end
  local derivation_request = {
    schema = execution.schemas.grant_request,
    execution_mode = plan.value.execution_mode,
    repository = copy(request.repository),
    preauthorization_ref = request.preauthorization_ref,
    preauthorization_sha256 = preauthorization.digest,
    plan_ref = request.plan_ref,
    plan_sha256 = plan.digest,
    environment_receipt_ref = request.environment_receipt_ref,
    environment_receipt_sha256 = environment.digest,
    grant_ref = request.grant_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    source_ref = { kind = "workflow-qa", ref = self.run_id },
  }
  local expected_grant = execution.derive_grant(
    preauthorization.value, preauthorization.digest,
    plan.value, plan.digest, environment.digest, derivation_request,
    execution_grant_values(self))
  if not equal(grant.value, expected_grant) then
    error("generic-host durable Grant differs from authenticated derivation")
  end
  local complete_preauthorization_request = preauthorization_request(preauthorization, request)
  local preauthorization_receipt = self:_persist_preauthorization_claim(
    complete_preauthorization_request, durable_claim)
  local verification_id = "grant-verification-" .. grant.digest:sub(1, 32)
  local durable = self.records:immutable(
    "testing-runner/grant-verifications/" .. self.records:digest(grant.digest), {
    binding = {
      grant_ref = request.grant_ref,
      grant_sha256 = grant.digest,
      preauthorization_ref = request.preauthorization_ref,
      preauthorization_sha256 = preauthorization.digest,
      plan_ref = request.plan_ref,
      plan_sha256 = plan.digest,
      environment_receipt_ref = request.environment_receipt_ref,
      environment_receipt_sha256 = environment.digest,
      repository = copy(request.repository),
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    },
    verification_id = verification_id,
    verified_at = self.execution_authorization_now,
  })
  if durable.written ~= true and durable.replayed ~= true then
    error("generic-host durable grant verification record differs")
  end
  local value = durable.value
  local source = lineage_source(self, {
      preauthorization_claim_receipt_ref = preauthorization_receipt.ref,
      preauthorization_claim_receipt_sha256 = preauthorization_receipt.sha256,
      grant_ref = request.grant_ref,
      grant_sha256 = grant.digest,
      grant_id = grant.value.grant_id,
      parent_authorization_ref = request.preauthorization_ref,
      parent_authorization_sha256 = preauthorization.digest,
      plan_ref = request.plan_ref,
      plan_sha256 = plan.digest,
      environment_receipt_ref = request.environment_receipt_ref,
      environment_receipt_sha256 = environment.digest,
      authority = copy(grant.value.authority),
      policy_revision = grant.value.policy_revision,
      evidence_ref = copy(grant.value.evidence_ref),
      verifier_ref = copy(self.grant_verifier_ref),
      verification_id = verification_id,
      verified_at = value.verified_at,
    })
  return self.lineage:write_receipt("grant_verification", verification_id,
    value.verified_at, receipt_fields(source), source)
end

function Context:_persist_execution_claim(request, durable_claim)
  if type(durable_claim) ~= "table" then
    error("generic-host durable execution claim binding differs")
  end
  local claimed_at = durable_claim.claimed_at or self.execution_authorization_now
  if type(durable_claim.claim_id) ~= "string"
    or type(claimed_at) ~= "string" or not equal(durable_claim.binding, request)
    or durable_claim.fence_id ~= self.lineage:fingerprint(
      "structured-execution-fence", durable_claim.claim_id) then
    error("generic-host durable execution claim binding differs")
  end
  local grant_record = self.records:read(
    "testing-runner/grant-verifications/" .. self.records:digest(request.grant_sha256))
  if type(grant_record) ~= "table" then
    error("generic-host durable Grant verification is unavailable")
  end
  local grant_request = copy(grant_record.binding)
  grant_request.grant = bound_artifact(self.store, grant_request.grant_ref,
    grant_request.grant_sha256, "execution grant").value
  local grant_receipt = self:_persist_grant_verification(grant_request)
  local preauthorization = bound_artifact(self.store, request.preauthorization_ref,
    request.preauthorization_sha256, "preauthorization")
  local preauthorization_claim = self.records:read(
    "generic-host/preauthorization/" .. self:_key(preauthorization.value.authorization_id))
  local complete_preauthorization_request = preauthorization_request(
    preauthorization, grant_record.binding)
  local preauthorization_receipt = self:_persist_preauthorization_claim(
    complete_preauthorization_request, preauthorization_claim)
  local fingerprint = self.lineage:fingerprint("structured-execution-claim", durable_claim.claim_id)
  local source = lineage_source(self, {
      grant_verification_receipt_ref = grant_receipt.ref,
      grant_verification_receipt_sha256 = grant_receipt.sha256,
      preauthorization_claim_receipt_ref = preauthorization_receipt.ref,
      preauthorization_claim_receipt_sha256 = preauthorization_receipt.sha256,
      grant_ref = request.grant_ref,
      grant_sha256 = request.grant_sha256,
      grant_id = request.grant_id,
      plan_ref = request.plan_ref,
      plan_sha256 = request.plan_sha256,
      environment_receipt_ref = request.environment_receipt_ref,
      environment_receipt_sha256 = request.environment_receipt_sha256,
      artifact_root = request.artifact_root,
      operation_id = request.operation_id,
      claim_fingerprint_sha256 = fingerprint,
      claimed_at = claimed_at,
    })
  return self.lineage:write_receipt("execution_claim",
    "execution-claim-" .. fingerprint:sub(1, 32), claimed_at,
    receipt_fields(source), source)
end

function Context:_authorization_lineage_sources(completion_receipt, completion_expected)
  local profile, profile_expected = self:_persist_profile_claim()
  local preauthorization_ref = self.request.structured_execution.preauthorization_ref
  local preauthorization = bound_artifact(self.store, preauthorization_ref,
    self.request.structured_execution.preauthorization_sha256, "preauthorization")
  local preauthorization_claim = self.records:read(
    "generic-host/preauthorization/" .. self:_key(preauthorization.value.authorization_id))
  if type(preauthorization_claim) ~= "table" then
    error("generic-host durable Preauthorization claim is unavailable")
  end
  local grant_ref = self.request.structured_execution.grant_ref
  local grant = bound_artifact(self.store, grant_ref, nil, "execution grant")
  local grant_record = self.records:read(
    "testing-runner/grant-verifications/" .. self.records:digest(grant.digest))
  if type(grant_record) ~= "table" then
    error("generic-host durable Grant verification is unavailable")
  end
  local complete_preauthorization_request = preauthorization_request(
    preauthorization, grant_record.binding)
  local preauthorization_receipt, preauthorization_expected = self:_persist_preauthorization_claim(
    complete_preauthorization_request, preauthorization_claim)
  local grant_receipt, grant_expected = self:_persist_grant_verification(grant_record.binding)
  local replay_entries = self.records:list("testing-runner/replay")
  if #replay_entries ~= 1 or type(replay_entries[1].value) ~= "table" then
    error("generic-host durable execution claim is unavailable")
  end
  local execution_receipt, execution_expected = self:_persist_execution_claim(
    replay_entries[1].value.binding, replay_entries[1].value)
  return {
    profile_claim = profile,
    preauthorization_claim = preauthorization_receipt,
    grant_verification = grant_receipt,
    execution_claim = execution_receipt,
    execution_completion = completion_receipt,
  }, {
    profile_claim = profile_expected,
    preauthorization_claim = preauthorization_expected,
    grant_verification = grant_expected,
    execution_claim = execution_expected,
    execution_completion = completion_expected,
  }
end

function Context:_execution_completion_source(durable_claim)
  local completed_at = type(durable_claim) == "table" and type(durable_claim.completion) == "table"
    and (durable_claim.completion.completed_at or self.execution_authorization_now) or nil
  if type(durable_claim) ~= "table" or durable_claim.status ~= "completed"
    or type(durable_claim.completion) ~= "table"
    or type(completed_at) ~= "string" then
    error("generic-host durable execution completion binding differs")
  end
  local completion = durable_claim.completion
  local execution_claim = self:_persist_execution_claim(durable_claim.binding, durable_claim)
  local execution_artifact, canonical = structured_execution_artifacts(self, completion.result_ref)
  if execution_artifact == nil or canonical == nil
    or execution_artifact.digest ~= completion.result_sha256 then
    error("generic-host durable canonical completion artifacts are unavailable")
  end
  if not execution_plan_matches_claim(execution_artifact, durable_claim) then
    error("generic-host durable completion Plan binding differs")
  end
  local source = lineage_source(self, {
      execution_claim_receipt_ref = execution_claim.ref,
      execution_claim_receipt_sha256 = execution_claim.sha256,
      result_ref = completion.result_ref,
      result_sha256 = execution_artifact.digest,
      case_result_set_ref = execution_artifact.value.case_result_set_path,
      case_result_set_artifact_sha256 = canonical.case_result_set.digest,
      evidence_manifest_ref = execution_artifact.value.evidence_manifest_path,
      evidence_manifest_artifact_sha256 = canonical.evidence_manifest.digest,
      completed_at = completed_at,
    })
  return source, completed_at, execution_artifact
end

function Context:_persist_execution_completion(durable_claim)
  local source, completed_at, execution_artifact = self:_execution_completion_source(durable_claim)
  local receipt, completion_expected = self.lineage:write_receipt("execution_completion",
    "execution-completion-" .. execution_artifact.digest:sub(1, 32), completed_at,
    receipt_fields(source), source)
  local artifacts, expected = self:_authorization_lineage_sources(receipt, completion_expected)
  self.lineage:write_index(completed_at, artifacts, expected)
  return receipt
end

function Context:authorization_lineage_evidence()
  local replay_entries = self.records:list("testing-runner/replay")
  if #replay_entries ~= 1 or type(replay_entries[1].value) ~= "table"
    or replay_entries[1].value.status ~= "completed" then
    error("generic-host durable completed execution claim is unavailable")
  end
  local source = self:_execution_completion_source(replay_entries[1].value)
  local completion = self.lineage:load_receipt("execution_completion", source)
  return self:_authorization_lineage_sources(completion, source)
end

function Context:_structured_runtime()
  local context = self
  local function replay_key(grant_id) return "testing-runner/replay/" .. context:_key(grant_id) end
  local function authorization_key(receipt_id)
    return "testing-runner/effect-authorizations/" .. context:_key(receipt_id)
  end
  local function argv_allowed(argv, capabilities)
    for _, capability in ipairs(capabilities or {}) do
      local prefix = capability.argv_prefix or {}
      local matches = #prefix > 0 and #prefix <= #argv
      for index, item in ipairs(prefix) do
        if argv[index] ~= item then matches = false break end
      end
      if matches then return true end
    end
    return false
  end
  local function http_allowed(request, capabilities, base_url)
    local base_origin = execution.local_http_origin(base_url)
    local origin, request_path = execution.local_http_origin(request and request.url)
    if base_origin == nil or origin ~= base_origin then return false end
    for _, capability in ipairs(capabilities or {}) do
      local capability_origin = execution.local_http_origin(capability.origin)
      local method_allowed = false
      for _, method in ipairs(capability.methods or {}) do
        if method == request.method then method_allowed = true end
      end
      if capability_origin == base_origin and method_allowed then
        for _, prefix in ipairs(capability.path_prefixes or {}) do
          if request_path:sub(1, #prefix) == prefix then return true end
        end
      end
    end
    return false
  end
  local function decision(envelope, value, reason, inputs)
    local envelope_sha256 = context.records:digest(json_codec.encode(envelope))
    local receipt = {
      schema = execution.schemas.effect_authorization_receipt,
      decision = value,
      reason_code = reason,
      receipt_id = "durable-" .. tostring(envelope.effect_kind or "invalid")
        .. "-effect-" .. envelope_sha256:sub(1, 32),
      envelope_sha256 = envelope_sha256,
      evaluated_input_digests = inputs,
      issued_at = "2026-07-22T00:20:00Z",
      expires_at = envelope.expires_at,
      fence_id = envelope.fence_id,
      trace_id = envelope.trace_id,
      dedup_key = envelope.dedup_key,
      auth_tag = context.records:digest(context.run_id .. "\0" .. envelope_sha256 .. "\0" .. value),
    }
    if value == "allow" then
      local stored = context.records:immutable(authorization_key(receipt.receipt_id), copy(receipt))
      if stored.written ~= true and stored.replayed ~= true then
        error("generic-host durable effect authorization receipt conflict")
      end
    end
    return receipt
  end
  local runtime = {
    sha256_bytes = function(bytes) return context.records:digest(bytes) end,
    load_artifact = function(path) return context.store:load(path) end,
    now = function(request)
      if request.artifact_root ~= context.request.structured_execution.artifact_root then
        error("generic-host durable structured runtime received a foreign artifact root")
      end
      return "2026-07-22T00:20:00Z"
    end,
    verify_grant = function(request)
      local grant = request.grant
      context:_persist_grant_verification(request)
      return {
        grant_sha256 = request.grant_sha256, authority = copy(grant.authority),
        policy_revision = grant.policy_revision, evidence_ref = copy(grant.evidence_ref),
      }
    end,
    replay_guard = function(request)
      local key = replay_key(request.grant_id)
      local claim_id = context:_private_claim_id("structured-execution")
      local fence_id = context.lineage:fingerprint("structured-execution-fence", claim_id)
      local claimed = context.records:claim(key, {
        status = "claimed", claim_id = claim_id, fence_id = fence_id, binding = copy(request),
        claimed_at = context.execution_authorization_now,
      })
      if claimed.claimed ~= true then return nil end
      local value = claimed.value
      context:_persist_execution_claim(request, value)
      if value.status == "completed" then
        context:_persist_execution_completion(value)
        return { status = "completed", result_ref = value.result_ref, result_sha256 = value.result_sha256 }
      end
      if claimed.replayed == true then return { status = "in-progress" } end
      return { status = "claimed", claim_id = value.fence_id }
    end,
    authorize_cli_effect = function(request)
      local envelope = request.action_envelope
      local ok = pcall(execution.validate_action_envelope, envelope)
      local empty = {
        profile = string.rep("0", 64), validation_receipt = string.rep("0", 64),
        preauthorization = string.rep("0", 64), environment_receipt = string.rep("0", 64),
        plan = string.rep("0", 64), grant = string.rep("0", 64),
      }
      if not ok then return decision(envelope, "deny", "malformed-envelope", empty) end
      local profile = context.store:load(envelope.profile_ref)
      local validation = context.store:load(envelope.validation_receipt_ref)
      local preauthorization = context.store:load(envelope.preauthorization_ref)
      local environment = context.store:load(envelope.environment_receipt_ref)
      local plan = context.store:load(envelope.plan_ref)
      local grant = context.store:load(envelope.grant_ref)
      local replay = type(grant) == "table" and type(grant.value) == "table"
        and context.records:read(replay_key(grant.value.grant_id)) or nil
      local inputs = {
        profile = profile and profile.digest or empty.profile,
        validation_receipt = validation and validation.digest or empty.validation_receipt,
        preauthorization = preauthorization and preauthorization.digest or empty.preauthorization,
        environment_receipt = environment and environment.digest or empty.environment_receipt,
        plan = plan and plan.digest or empty.plan,
        grant = grant and grant.digest or empty.grant,
      }
      if profile == nil or validation == nil or preauthorization == nil
        or environment == nil or plan == nil or grant == nil then
        return decision(envelope, "deny", "missing-input", inputs)
      end
      local valid = pcall(project_profile.validate_profile, profile.value)
        and pcall(project_profile.validate_validation_receipt, validation.value)
        and pcall(execution.validate_preauthorization, preauthorization.value, "2026-07-22T00:20:00Z")
        and pcall(environment_factory.validate_receipt, environment.value)
        and pcall(execution.validate_plan, plan.value)
        and pcall(execution.validate_grant, grant.value, "2026-07-22T00:20:00Z")
      local planned_case
      for _, item in ipairs(plan.value.cases or {}) do
        if item.case_id == envelope.case.case_id then planned_case = item end
      end
      local effect_allowed = envelope.effect_kind == "cli"
        and argv_allowed(envelope.case.argv, preauthorization.value.capabilities.cli)
        and argv_allowed(envelope.case.argv, grant.value.cli_capabilities)
        or envelope.effect_kind == "http" and envelope.base_url == environment.value.base_url
          and http_allowed(envelope.case.request, preauthorization.value.capabilities.http, envelope.base_url)
          and http_allowed(envelope.case.request, grant.value.http_capabilities, envelope.base_url)
      if not valid or profile.digest ~= envelope.profile_artifact_sha256
        or project_profile.profile_sha256(profile.value, function(body) return context.records:digest(body) end)
          ~= envelope.profile_sha256
        or validation.digest ~= envelope.validation_receipt_sha256
        or validation.value.profile_sha256 ~= envelope.profile_sha256
        or preauthorization.digest ~= envelope.preauthorization_sha256
        or preauthorization.value.profile_sha256 ~= envelope.profile_sha256
        or environment.digest ~= envelope.environment_receipt_sha256
        or plan.value.environment_receipt_sha256 ~= environment.digest
        or plan.digest ~= envelope.plan_sha256 or grant.digest ~= envelope.grant_sha256
        or grant.value.parent_authorization_sha256 ~= preauthorization.digest
        or grant.value.plan_sha256 ~= plan.digest
        or grant.value.environment_receipt_sha256 ~= environment.digest
        or not equal(environment.value.workspace_ref, envelope.workspace_ref)
        or type(replay) ~= "table" or replay.status ~= "claimed"
        or replay.fence_id ~= envelope.fence_id
        or not equal(planned_case, envelope.case)
        or not effect_allowed then
        return decision(envelope, "deny", "foreign-binding", inputs)
      end
      return decision(envelope, "allow", "authorized", inputs)
    end,
    exec_argv = function(request)
      local envelope = request.action_envelope
      local receipt = request.authorization_receipt
      execution.validate_cli_action_envelope(envelope)
      execution.validate_effect_authorization_receipt(receipt, envelope, "2026-07-22T00:20:00Z")
      local issued = context.records:read(authorization_key(receipt.receipt_id))
      if receipt.decision ~= "allow"
        or receipt.envelope_sha256 ~= context.records:digest(json_codec.encode(envelope))
        or issued == nil or not equal(issued, receipt) then
        error("generic-host durable structured CLI authorization receipt is unavailable")
      end
      local consumed = context.records:claim(
        "testing-runner/effect-consumptions/" .. context:_key(receipt.receipt_id),
        { binding = copy(receipt), receipt_id = receipt.receipt_id })
      if consumed.claimed ~= true or consumed.replayed == true then
        error("generic-host durable structured CLI authorization receipt is replayed")
      end
      if envelope.operation_id ~= context.run_id
        or type(envelope.workspace_ref) ~= "table"
        or envelope.workspace_ref.ref ~= context.run_id .. "-workspace"
        or envelope.repository.commit_sha ~= context.commit_sha then
        error("generic-host durable structured CLI request is not bound to the ready workspace")
      end
      local workspace = context.records:read(context:_resource("environment-factory", envelope.workspace_ref))
      if workspace == nil then error("generic-host durable structured workspace is unavailable") end
      local result = direct_exec(envelope.case.argv, workspace.path)
      context.records:immutable("testing-runner/target-effects/" .. context:_key(request), {
        binding = copy(request), result = copy(result),
      })
      return result
    end,
    http_request = function(input)
      local envelope = input.action_envelope
      local receipt = input.authorization_receipt
      execution.validate_http_action_envelope(envelope)
      execution.validate_effect_authorization_receipt(receipt, envelope, "2026-07-22T00:20:00Z")
      local issued = context.records:read(authorization_key(receipt.receipt_id))
      if receipt.decision ~= "allow"
        or receipt.envelope_sha256 ~= context.records:digest(json_codec.encode(envelope))
        or issued == nil or not equal(issued, receipt) then
        error("generic-host durable structured HTTP authorization receipt is unavailable")
      end
      local consumed = context.records:claim(
        "testing-runner/effect-consumptions/" .. context:_key(receipt.receipt_id),
        { binding = copy(receipt), receipt_id = receipt.receipt_id })
      if consumed.claimed ~= true or consumed.replayed == true then
        error("generic-host durable structured HTTP authorization receipt is replayed")
      end
      if envelope.operation_id ~= context.run_id or envelope.base_url ~= context.base_url
        or envelope.case.request.url ~= context.base_url then
        error("generic-host durable structured HTTP request is not bound to the ready environment")
      end
      local result = http_request(envelope.case.request, envelope.case.timeout_seconds)
      context.records:immutable("testing-runner/target-effects/" .. context:_key(input), {
        binding = copy(input), result = copy(result),
      })
      return result
    end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    load_result = function(request)
      local artifact = structured_execution_artifacts(context, request.result_ref)
      local durable_claim = durable_execution_claim(context, "completed")
      if artifact == nil or (request.result_sha256 ~= nil and artifact.digest ~= request.result_sha256) then return nil end
      local value = artifact.value
      if not execution_plan_matches_claim(artifact, durable_claim)
        or durable_claim.result_ref ~= request.result_ref
        or durable_claim.result_sha256 ~= request.result_sha256
        or value.operation_id ~= request.operation_id
        or value.environment_receipt_sha256 ~= request.environment_receipt_sha256
        or not execution.same_repository(value.repository, request.repository)
        or value.trace_id ~= request.trace_id or value.dedup_key ~= request.dedup_key then return nil end
      local summary = {
        schema = "testing-runner.structured-execution-summary.v1", status = value.status,
        classification = value.classification, mode = "structured-api-cli",
        artifact_root = context.request.structured_execution.artifact_root,
        case_count = value.case_count, passed_count = value.passed_count, failed_count = value.failed_count,
        skipped_count = value.skipped_count, error_count = value.error_count,
        test_plan_path = value.test_plan_path, case_results_path = value.case_results_path,
        execution_path = value.execution_path, replayed = true,
      }
      if value.case_result_set_path ~= nil then
        summary.case_result_set_path = value.case_result_set_path
        summary.case_result_set_artifact_sha256 = value.case_result_set_artifact_sha256
        summary.evidence_manifest_path = value.evidence_manifest_path
        summary.evidence_manifest_artifact_sha256 = value.evidence_manifest_artifact_sha256
      end
      return summary
    end,
    complete_replay = function(request)
      local current
      for _, entry in ipairs(context.records:list("testing-runner/replay")) do
        if type(entry.value) == "table" and entry.value.fence_id == request.claim.claim_id then
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
      local artifact, canonical = structured_execution_artifacts(context, request.result_ref)
      local value = artifact and artifact.value or nil
      if value == nil or value.operation_id ~= request.operation_id
        or binding.plan_sha256 ~= value.plan_sha256
        or value.environment_receipt_sha256 ~= request.environment_receipt_sha256
        or not execution.same_repository(value.repository, request.repository)
        or value.trace_id ~= request.trace_id or value.dedup_key ~= request.dedup_key then
        return false
      end
      local completion = copy(request)
      completion.claim = nil
      completion.result_sha256 = artifact.digest
      completion.completed_at = context.execution_authorization_now
      local completed = context.records:complete_replay(current.key, current.value.claim_id, completion)
      if completed.completed ~= true then return false end
      local verified, verified_canonical = structured_execution_artifacts(context, request.result_ref)
      if verified.digest ~= artifact.digest
        or (canonical ~= nil and (verified_canonical == nil
          or verified_canonical.case_result_set.digest ~= canonical.case_result_set.digest
          or verified_canonical.evidence_manifest.digest ~= canonical.evidence_manifest.digest)) then
        error("generic-host durable canonical execution artifacts changed during replay completion")
      end
      context:_persist_execution_completion(completed.value)
      return true
    end,
  }
  runtime.authorize_http_effect = runtime.authorize_cli_effect
  return runtime
end

function Context:_publication_runtime()
  local context = self
  return {
    sha256_bytes = function(bytes, artifact_root)
      local execution_root = context.request.structured_execution.artifact_root
      if artifact_root ~= context.artifact_root and artifact_root ~= execution_root then
        error("generic-host durable publication hash received a foreign artifact root")
      end
      return context.records:digest(bytes)
    end,
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
    claim_qa_run_intake = function(value)
      local claimed = context.records:claim("generic-host/local-qa-intake/" .. context.run_id, {
        binding = copy(value), claim_id = context.run_id .. "-local-qa-intake",
      })
      if claimed.claimed ~= true then return { status = "blocked" } end
      return {
        status = "claimed", claim_id = claimed.value.claim_id, replayed = claimed.replayed == true,
      }
    end,
    claim_preauthorization = function(value)
      local key = "generic-host/preauthorization/" .. context:_key(value.authorization_id)
      local existing = context.records:read(key)
      local claimed
      if existing ~= nil then
        claimed = {
          claimed = preauthorization_binding_matches(
            existing.binding, value, trusted_preauthorization_refs(context)),
          replayed = true,
          value = existing,
        }
      else
        claimed = context.records:claim(key, {
          binding = canonical_preauthorization_binding(value),
          claim_id = context:_private_claim_id("structured-preauthorization"),
          claimed_at = context.execution_authorization_now,
        })
      end
      if claimed.claimed ~= true then return { status = "blocked" } end
      context:_persist_preauthorization_claim(value, claimed.value)
      return {
        status = "claimed", claim_id = claimed.value.claim_id, replayed = claimed.replayed == true,
      }
    end,
    reconcile_preauthorization_claim = function(value)
      local preauthorization = bound_artifact(context.store, value.preauthorization_ref,
        value.preauthorization_sha256, "preauthorization")
      local request = copy(value)
      request.authorization_id = preauthorization.value.authorization_id
      local claimed = context.records:read(
        "generic-host/preauthorization/" .. context:_key(request.authorization_id))
      if claimed == nil or not preauthorization_binding_matches(
        claimed.binding, request, trusted_preauthorization_refs(context)) then return false end
      context:_persist_preauthorization_claim(request, claimed)
      return true
    end,
    grant_values = function() return execution_grant_values(context) end,
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
  local execution_artifact = structured_execution_artifacts(self, outcome.execution_path)
  local witness = {
    run_id = self.run_id,
    result_ref = outcome.execution_path,
    result_sha256 = execution_artifact.digest,
    replay_status = claims[1].value.status,
  }
  local execution_value = execution_artifact.value
  if execution_value.case_result_set_path ~= nil then
    witness.case_result_set_ref = execution_value.case_result_set_path
    witness.case_result_set_artifact_sha256 = execution_value.case_result_set_artifact_sha256
    witness.evidence_manifest_ref = execution_value.evidence_manifest_path
    witness.evidence_manifest_artifact_sha256 = execution_value.evidence_manifest_artifact_sha256
  end
  local barrier = self.records:immutable("generic-host/barriers/post-replay-complete", witness)
  if barrier.written ~= true then return end
  local handle = io.open(fifo, "r")
  if handle ~= nil then handle:read("*l") handle:close() end
end

function Context:terminal_record()
  return self.records:read("generic-host/terminal/" .. self.run_id)
end

local function authorization_context(config, records, store, projector)
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
      local nonce = next_nonce()
      local claimed = records:claim("generic-host/profile-approval/" .. config.run_id, {
        binding = copy(value),
        claim_id = "private-claim-" .. records:digest(
          config.lineage_projection_secret .. "\0project-profile\0" .. nonce),
        claimed_at = config.authorization_now,
      })
      if claimed.claimed == true then
        profile_claim_receipt(config, store, projector, claimed.value)
      end
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
  context.profile_source_ref = copy(config.profile_source_ref)
  context.grant_verifier_ref = copy(config.grant_verifier_ref)
  context.execution_authorization_now = config.execution_authorization_now
  context.lineage = lineage_projection.new({
    store = context.store,
    sha256 = function(body) return records:digest(body) end,
    repository = { url = config.repository.url, commit_sha = config.repository.commit_sha },
    run_id = config.run_id,
    trace_id = config.request.trace_id,
    dedup_key = config.request.dedup_key,
    artifact_root = config.artifact_root,
    fingerprint_secret = config.lineage_projection_secret,
  })
  context.authorization_context = authorization_context(config, records, context.store, context.lineage)
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
  local immutable_design_inputs = design_inputs(context.request)
  require_design_input_sources(context, immutable_design_inputs)
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
    target_execution_boundary = {
      schema = "testing-host.target-execution-boundary.v1",
      mode = "trusted-fixture-exact",
      target_class = "host-owned-exact-trusted-fixture",
      repository = copy(context.profile.repository),
      authority = {
        kind = "host-policy", ref = "fixtures/" .. context.fixture_name .. "-target-execution-boundary",
      },
      policy_revision = "generic-host-trusted-fixture-exact-v1",
      authorization_capability = false,
      execution_authorized = false,
    },
    profile = copy(context.profile),
    approval = copy(context.approval),
    validation_receipt = copy(context.validation_receipt),
    profile_source_ref = {
      kind = "host-profile-policy", ref = "fixtures/" .. context.fixture_name .. "-profile",
    },
    grant_verifier_ref = {
      kind = "host-verifier", ref = "fixtures/" .. context.fixture_name .. "-grant-verifier",
    },
    lineage_projection_secret = context.lineage_projection_secret,
    authorization_now = context.authorization_context.now,
    execution_authorization_now = "2026-07-22T00:20:00Z",
    authorization_approval_ref = copy(context.authorization_context.approval_ref),
    completed_replay_failpoint = copy(context.completed_replay_failpoint),
    crash_barrier = copy(context.crash_barrier),
    runtime_pep_denial = copy(context.runtime_pep_denial),
    fixture_name = context.fixture_name,
    fixture_source_root = context.fixture_source_root,
    use_local_qa_departments = context.use_local_qa_departments == true,
    local_qa_department_calls = {},
    temp_root_prefix = context.temp_root_prefix,
    artifact_root_prefix = context.artifact_root_prefix,
    request = copy(context.request),
  }
  local stored = records:immutable("generic-host/config", config)
  if stored.written ~= true and stored.replayed ~= true then error("generic-host durable config binding differs") end
  local initial_paths = {
    context.request.environment_start.profile_ref.ref,
    context.request.environment_start.approval_ref.ref,
    context.request.environment_start.validation_receipt_ref.ref,
    context.request.analysis_request.repository.approval_ref.ref,
    context.request.structured_execution.case_catalog_ref,
    context.request.structured_execution.preauthorization_ref,
  }
  for _, input in ipairs(immutable_design_inputs) do
    table.insert(initial_paths, input.reference.artifact_pointer)
  end
  for _, path in ipairs(initial_paths) do
    if type(path) ~= "string" or path:sub(1, 14) ~= ".testing/runs/"
      or path:find("..", 1, true) or path:find("\\", 1, true) then
      error("generic-host durable initial artifact path is invalid: " .. tostring(path))
    end
    local artifact = context.store:load(path)
    if artifact == nil or records:write_artifact(path, artifact.raw).written ~= true then
      error("generic-host durable initial artifact write failed: " .. tostring(path))
    end
    write_file(context.project_root .. "/" .. path, artifact.raw)
  end
  for _, input in ipairs(immutable_design_inputs) do verify_design_input(context.project_root, input) end
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

function M.supervisor_action(context)
  local state = context.workflow_runtime.load_state(context.request.state_ref)
  if state == nil and context.use_local_qa_departments == true then
    local outbox = context.records:immutable("generic-host/local-qa-startup-outbox/" .. context.run_id, {
      schema = "generic-host.local-qa-startup-outbox.v1",
      queue = "local-qa-host-adapter.qa_run_request",
      payload = copy(context.request),
    })
    if outbox.written ~= true and outbox.replayed ~= true then
      error("generic-host durable Local QA startup outbox binding differs")
    end
    return { queue = outbox.value.queue, payload = outbox.value.payload }, "intake"
  end
  return {
    queue = "workflow-qa.workflow_qa_tick",
    payload = { run_id = context.run_id, limit = 1 },
  }, "redrive"
end

M.copy = copy
M.equal = equal
M.run_root = run_root

return M
