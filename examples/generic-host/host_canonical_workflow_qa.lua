local browser_readiness = require("contract.browser_readiness")
local execution = require("contract.structured_execution")
local environment_factory = require("contract.environment_factory")
local json_codec = require("testing_runtime.json")
local project_profile = require("contract.project_profile")
local design_loop = require("testing_ai.module_ai_design_loop")
local workflow_qa = require("contract.workflow_qa")

local M = {}

local fixture_support = require("host_canonical_workflow_qa_support")
local project_root = fixture_support.project_root
local copy = fixture_support.copy
local equal = fixture_support.equal
local shell_quote = fixture_support.shell_quote
local read_file = fixture_support.read_file
local write_file = fixture_support.write_file
local direct_exec = fixture_support.direct_exec
local require_exec = fixture_support.require_exec
local remove_tree = fixture_support.remove_tree
local prepare_supervisor_project = fixture_support.prepare_supervisor_project
local absolute = fixture_support.absolute
local sha256_bytes = fixture_support.sha256_bytes
local reserve_port = fixture_support.reserve_port
local ref = fixture_support.ref
local Store = fixture_support.Store
local artifact_reference = fixture_support.artifact_reference
local spawn_process = fixture_support.spawn_process
local wait_http = fixture_support.wait_http
local http_request = fixture_support.http_request

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
      local module_id = context.fixture_name == "downstream-inventory" and "inventory" or "service"
      local docs = {
        repository_analysis = {
          path = root .. "/repository-analysis.v1.json",
          schema = "testing-design.repository-analysis.v1",
          value = { schema = "testing-design.repository-analysis.v1", repository = copy(request.repository), modules = { module_id } },
        },
        requirements_index = {
          path = root .. "/requirements-index.v1.json",
          schema = "testing-design.requirements-index.v1",
          value = { schema = "testing-design.requirements-index.v1", requirements = { { id = "REQ-HEALTH", priority = "P0" } } },
        },
        traceability_seed = {
          path = root .. "/traceability-seed.v1.json",
          schema = "testing-design.traceability-seed.v1",
          value = { schema = "testing-design.traceability-seed.v1", links = { { requirement = "REQ-HEALTH", module = module_id } } },
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
  local authorizations = {}
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
  local function decision(envelope, value, reason, inputs)
    local envelope_sha256 = sha256_bytes(json_codec.encode(envelope))
    local receipt = {
      schema = execution.schemas.effect_authorization_receipt,
      decision = value,
      reason_code = reason,
      receipt_id = "canonical-cli-effect-" .. envelope_sha256:sub(1, 32),
      envelope_sha256 = envelope_sha256,
      evaluated_input_digests = inputs,
      issued_at = "2026-07-22T00:20:00Z",
      expires_at = envelope.expires_at,
      fence_id = envelope.fence_id,
      trace_id = envelope.trace_id,
      dedup_key = envelope.dedup_key,
      auth_tag = sha256_bytes(context.run_id .. "\0" .. envelope_sha256 .. "\0" .. value),
    }
    if value == "allow" then authorizations[receipt.receipt_id] = copy(receipt) end
    return receipt
  end
  return {
    load_artifact = function(path) return context.store:load(path) end,
    now = function(request)
      if request.artifact_root ~= context.request.structured_execution.artifact_root then
        error("canonical structured runtime received a foreign artifact root")
      end
      return "2026-07-22T00:20:00Z"
    end,
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
        return { status = "in-progress" }
      end
      claim = { claim_id = context.run_id .. "-execution-claim" }
      claims[request.grant_id] = claim
      context.execution_claims = context.execution_claims + 1
      return { status = "claimed", claim_id = claim.claim_id }
    end,
    authorize_cli_effect = function(request)
      local envelope = request.action_envelope
      local ok = pcall(execution.validate_cli_action_envelope, envelope)
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
      local evaluated_plan = copy(plan.value)
      if context.pep_mutate_plan_binding == true then
        evaluated_plan.environment_receipt_sha256 = string.rep("0", 64)
      end
      local planned_case
      for _, item in ipairs(evaluated_plan.cases or {}) do
        if item.case_id == envelope.case.case_id then planned_case = item end
      end
      if not valid or profile.digest ~= envelope.profile_artifact_sha256
        or project_profile.profile_sha256(profile.value, sha256_bytes) ~= envelope.profile_sha256
        or validation.digest ~= envelope.validation_receipt_sha256
        or validation.value.profile_sha256 ~= envelope.profile_sha256
        or preauthorization.digest ~= envelope.preauthorization_sha256
        or preauthorization.value.profile_sha256 ~= envelope.profile_sha256
        or environment.digest ~= envelope.environment_receipt_sha256
        or evaluated_plan.environment_receipt_sha256 ~= environment.digest
        or plan.digest ~= envelope.plan_sha256 or grant.digest ~= envelope.grant_sha256
        or grant.value.parent_authorization_sha256 ~= preauthorization.digest
        or grant.value.plan_sha256 ~= plan.digest
        or grant.value.environment_receipt_sha256 ~= environment.digest
        or not equal(environment.value.workspace_ref, envelope.workspace_ref)
        or not equal(planned_case, envelope.case)
        or not argv_allowed(envelope.case.argv, preauthorization.value.capabilities.cli)
        or not argv_allowed(envelope.case.argv, grant.value.cli_capabilities) then
        return decision(envelope, "deny", "foreign-binding", inputs)
      end
      return decision(envelope, "allow", "authorized", inputs)
    end,
    exec_argv = function(request)
      local envelope = request.action_envelope
      local receipt = request.authorization_receipt
      execution.validate_cli_action_envelope(envelope)
      execution.validate_effect_authorization_receipt(receipt, envelope, "2026-07-22T00:20:00Z")
      local issued = authorizations[receipt.receipt_id]
      if receipt.decision ~= "allow" or issued == nil or not equal(issued, receipt) then
        error("canonical structured CLI authorization receipt is unavailable or replayed")
      end
      authorizations[receipt.receipt_id] = nil
      if envelope.operation_id ~= context.run_id
        or envelope.workspace_ref.ref ~= context.run_id .. "-workspace"
        or envelope.repository.commit_sha ~= context.commit_sha then
        error("canonical structured CLI request is not bound to the ready workspace")
      end
      table.insert(context.target_effects, { kind = "cli", argv = copy(envelope.case.argv) })
      return direct_exec(envelope.case.argv, context.workspace_root)
    end,
    http_request = function(input)
      if input.operation_id ~= context.run_id or input.base_url ~= context.base_url
        or input.request.url ~= context.base_url then
        error("canonical structured HTTP request is not bound to the ready environment")
      end
      table.insert(context.target_effects, {
        kind = "http", method = input.request.method, url = input.request.url,
      })
      return http_request(input.request, input.timeout_seconds)
    end,
    write_artifact = function(path, value) return context.store:write(path, value) end,
    load_result = function(request)
      local artifact = context.store:load(request.result_ref)
      if artifact == nil then return nil end
      local value = artifact.value
      return {
        schema = "testing-runner.structured-execution-summary.v1",
        status = value.status, classification = value.classification,
        mode = "structured-api-cli", artifact_root = context.request.structured_execution.artifact_root,
        case_count = value.case_count, passed_count = value.passed_count,
        failed_count = value.failed_count, skipped_count = value.skipped_count,
        error_count = value.error_count, test_plan_path = value.test_plan_path,
        case_results_path = value.case_results_path, execution_path = value.execution_path,
        replayed = true,
      }
    end,
    complete_replay = function(request)
      for _, stored in pairs(claims) do
        if stored.claim_id == request.claim.claim_id then
          stored.completed = true
          stored.result_ref = request.result_ref
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
  return require("test_support.host_workflow_qa_supervisor").run(self, project_root)
end

function Context:framework_environment(label, arm_failpoint)
  if type(label) ~= "string" or label == "" or label:find("[^A-Za-z0-9._-]") then
    error("canonical workflow supervisor label is invalid")
  end
  local runtime_cli = self.project_root .. "/packages/generic-host/bin/generic-host-runtime.js"
  local environment = {
    FKST_RUNTIME_ROOT = self.host_root .. "/framework-runtime-" .. label,
    FKST_DURABLE_ROOT = self.host_root .. "/framework-durable-" .. label,
    FKST_GENERIC_HOST_DURABLE_ROOT = self.durable_root,
    FKST_GENERIC_HOST_PROJECT_ROOT = self.project_root,
    FKST_ENVIRONMENT_FACTORY_RUNTIME_CLI = runtime_cli,
    FKST_ENVIRONMENT_FACTORY_RUNTIME_CONFIG_REF = self.runtime_config_ref,
    FKST_STRUCTURED_EXECUTION_RUNTIME_CLI = runtime_cli,
    FKST_STRUCTURED_EXECUTION_RUNTIME_CONFIG_REF = self.runtime_config_ref,
    FKST_WORKFLOW_QA_RUNTIME_CLI = runtime_cli,
    FKST_WORKFLOW_QA_RUNTIME_CONFIG_REF = self.runtime_config_ref,
    FKST_QA_PUBLICATION_RUNTIME_CLI = runtime_cli,
    FKST_QA_PUBLICATION_RUNTIME_CONFIG_REF = self.runtime_config_ref,
    FKST_WORKFLOW_QA_ADAPTER_RUNTIME_CLI = runtime_cli,
    FKST_WORKFLOW_QA_ADAPTER_RUNTIME_CONFIG_REF = self.runtime_config_ref,
    FKST_MODULE_TEST_LOOP_TEST_RUNTIME = "0",
  }
  if arm_failpoint == true and type(self.completed_replay_failpoint) == "table" then
    environment.FKST_DURABLE_COMPLETED_REPLAY_FAILPOINT = self.completed_replay_failpoint.token
  elseif type(arm_failpoint) == "string" and type(self.crash_barrier) == "table"
    and self.crash_barrier.name == arm_failpoint then
    environment.FKST_DURABLE_CRASH_BARRIER = self.crash_barrier.token
  end
  if type(self.runtime_pep_denial) == "table" then
    environment.FKST_GENERIC_HOST_FIXTURE_CLI_DENY_TOKEN = self.runtime_pep_denial.token
  end
  return environment
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
    local_qa_workflow_qa_runtime = self.generic_host_runtime,
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
  if self.durable_root ~= nil then
    local ok, recovered = pcall(function()
      return require("host_durable_workflow_qa").load(self.project_root, self.durable_root, self.run_id)
    end)
    if ok then
      local common = {
        run_id = self.run_id,
        operation_id = self.run_id,
        artifact_root = self.artifact_root .. "/environment",
        trace_id = self.request.trace_id,
        dedup_key = self.request.dedup_key,
        timeout_seconds = 2,
      }
      for _, cleanup_ref in ipairs({
        { kind = "process-cleanup", ref = self.run_id .. "-application" },
        { kind = "workspace-cleanup", ref = self.run_id .. "-workspace" },
        { kind = "port-lease", ref = self.run_id .. "-ports" },
      }) do
        pcall(function()
          local request = copy(common)
          request.cleanup_ref = cleanup_ref
          request.effect_id = self.run_id .. "/test-teardown/" .. cleanup_ref.kind
          recovered:_fixture_effect("cleanup", request, 2)
        end)
      end
    end
  end
  remove_tree(self.temp_root, self.temp_root_prefix)
  remove_tree(absolute(self.artifact_root), self.artifact_root_prefix)
end

function M.new(options)
  options = options or {}
  local inventory = options.scenario == "downstream-inventory"
  local port = reserve_port()
  local cdp_port = reserve_port()
  local run_prefix = inventory and "inventory-initial-state-" or "canonical-workflow-qa-"
  local fixture_name = inventory and "downstream-inventory" or "canonical-qa"
  local run_id = run_prefix .. tostring(port)
  local artifact_root = ".testing/runs/" .. run_id
  local temp_root = "/tmp/fkst-generic-host-" .. run_id
  local source_root = temp_root .. "/source"
  local workspace_root = temp_root .. "/workspace"
  local host_root = temp_root .. "/host"
  require_exec({ "rm", "-rf", temp_root, absolute(artifact_root) })
  require_exec({ "mkdir", "-p", source_root, host_root })
  local durable_enabled = options.durable == true or options.durable_root ~= nil
  local supervisor_project_root = project_root
  if durable_enabled then
    supervisor_project_root = temp_root .. "/supervisor-project"
    prepare_supervisor_project(supervisor_project_root)
  end
  require_exec({
    "node", "-e",
    "const fs=require('fs');fs.cpSync(process.argv[1],process.argv[2],{recursive:true});",
    absolute("examples/generic-host/fixtures/" .. fixture_name), source_root,
  })
  require_exec({ "git", "init", "--quiet" }, source_root)
  require_exec({ "git", "config", "user.email", "fixture@example.invalid" }, source_root)
  require_exec({ "git", "config", "user.name", "Generic Host Fixture" }, source_root)
  require_exec({ "git", "add", "." }, source_root)
  require_exec({ "git", "commit", "--quiet", "-m", fixture_name .. " fixture" }, source_root)
  write_file(source_root .. "/source-only-uncommitted.txt", "must not enter the detached test checkout\n")
  local commit_sha = require_exec({ "git", "rev-parse", "HEAD" }, source_root):match("([0-9a-f]+)")
  local store = Store.new()
  local repository = {
    slug = inventory and "fixture/downstream-inventory" or "owner/canonical-qa",
    url = inventory and "https://example.invalid/fixtures/downstream-inventory.git"
      or "https://example.invalid/generic/canonical-qa.git",
    commit_sha = commit_sha,
  }
  local trace_id = "trace-" .. run_id
  local dedup_key = run_id
  local origin = "http://127.0.0.1:" .. tostring(port)
  local base_url = origin .. (inventory and "/inventory/SKU-001" or "/health")
  local profile_ref = ref(artifact_root .. "/authorization/profile.json")
  local approval_ref = ref(artifact_root .. "/authorization/approval.json")
  local validation_ref = ref(artifact_root .. "/authorization/profile-validation.json")
  local authority = { kind = "host-policy", ref = "fixtures/" .. fixture_name }
  local evidence = { kind = "signed-attestation", ref = "fixtures/" .. fixture_name .. "-approval" }
  local profile = {
    schema = project_profile.schemas.profile,
    revision = fixture_name .. "-profile-v1",
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
    mutation_policy = inventory and {
      mode = "fixture-scoped", allowed_operations = { "update" }, cleanup_required = true,
    } or { mode = "read-only" },
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
    policy_revision = fixture_name .. "-policy-v1",
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
    policy_revision = fixture_name .. "-policy-v1",
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
  local analysis_approval_ref = ref(artifact_root .. "/authorization/testing-design-repository.json")
  local analysis_approval = {
    schema = "testing-design.approval.v1",
    subject_kind = "repository",
    repository_url = repository.url,
    workspace_ref = { kind = "workspace", ref = workspace_root },
    target_commit_sha = commit_sha,
    baseline_commit_sha = commit_sha,
  }
  assert(store:write(analysis_approval_ref.ref, analysis_approval))

  local catalog_ref = artifact_root .. "/execution/case-catalog.json"
  local effect_counter_path = options.effect_counter_path
  if effect_counter_path == nil and options.count_effect == true then
    effect_counter_path = temp_root .. "/effect-invocations"
  end
  local cli_argv = { "node", "cli.js", "--version" }
  if effect_counter_path ~= nil then
    cli_argv = { "node", "cli.js", "--count-effect", effect_counter_path, "--version" }
  end
  local completed_replay_failpoint
  if options.arm_completed_replay_failpoint == true then
    completed_replay_failpoint = {
      name = "post-completed-replay",
      token = sha256_bytes(run_id .. "\0post-completed-replay"),
    }
  end
  local crash_barrier_names = {
    ["workflow-before-state-save"] = true,
    ["workflow-after-state-save"] = true,
    ["cleanup-after-effect"] = true,
    ["publication-after-effect"] = true,
  }
  local crash_barrier
  if type(options.crash_barrier) == "string" then
    if crash_barrier_names[options.crash_barrier] ~= true then
      error("canonical workflow crash barrier is invalid")
    end
    crash_barrier = {
      name = options.crash_barrier,
      token = sha256_bytes(run_id .. "\0" .. options.crash_barrier),
    }
  end
  local runtime_pep_denial
  if options.runtime_pep_deny_reason ~= nil then
    if options.runtime_pep_deny_reason ~= "profile-policy-denied" then
      error("canonical workflow runtime PEP deny reason is invalid")
    end
    runtime_pep_denial = {
      reason_code = options.runtime_pep_deny_reason,
      token = sha256_bytes(run_id .. "\0fixture-cli-effect-denial"),
    }
  end
  local catalog_cases = {}
  if inventory then
    catalog_cases = {
      {
      design_case_id = "inventory-initial-state",
      case_id = "inventory-initial-state",
      kind = "http",
      request = { method = "GET", url = base_url, headers = {} },
      timeout_seconds = 10,
      assertions = {
        { type = "status-code", expected = 200 },
        { type = "body-contains", expected = "\"sku\":\"SKU-001\"" },
        { type = "body-contains", expected = "\"on_hand\":5" },
        { type = "body-contains", expected = "\"reserved\":0" },
        { type = "body-contains", expected = "\"available\":5" },
      },
      },
      {
        design_case_id = "inventory-reserve-three",
        case_id = "inventory-reserve-three",
        kind = "cli",
        argv = { "node", "cli.js", "reserve", "SKU-001", "3" },
        timeout_seconds = 10,
        assertions = { { type = "exit-code", expected = 0 } },
      },
      {
        design_case_id = "inventory-state-after-reserve",
        case_id = "inventory-state-after-reserve",
        kind = "http",
        request = { method = "GET", url = base_url, headers = {} },
        timeout_seconds = 10,
        assertions = {
          { type = "status-code", expected = 200 },
          { type = "body-contains", expected = "\"sku\":\"SKU-001\"" },
          { type = "body-contains", expected = "\"on_hand\":5" },
          { type = "body-contains", expected = "\"reserved\":3" },
          { type = "body-contains", expected = "\"available\":2" },
        },
      },
      {
        design_case_id = "inventory-over-reserve-rejected",
        case_id = "inventory-over-reserve-rejected",
        kind = "cli",
        argv = { "node", "cli.js", "reserve", "SKU-001", "3" },
        timeout_seconds = 10,
        assertions = { { type = "exit-code", expected = 4 } },
      },
      {
        design_case_id = "inventory-state-after-rejection",
        case_id = "inventory-state-after-rejection",
        kind = "http",
        request = { method = "GET", url = base_url, headers = {} },
        timeout_seconds = 10,
        assertions = {
          { type = "status-code", expected = 200 },
          { type = "body-contains", expected = "\"sku\":\"SKU-001\"" },
          { type = "body-contains", expected = "\"on_hand\":5" },
          { type = "body-contains", expected = "\"reserved\":3" },
          { type = "body-contains", expected = "\"available\":2" },
        },
      },
    }
  else
    table.insert(catalog_cases, {
      design_case_id = "service:reachability",
      case_id = "cli-version",
      kind = "cli",
      argv = cli_argv,
      timeout_seconds = 10,
      assertions = { { type = "exit-code", expected = 0 } },
    })
    if options.cli_only ~= true then
      table.insert(catalog_cases, {
        design_case_id = "service:page-load",
        case_id = "health",
        kind = "http",
        request = { method = "GET", url = base_url, headers = {} },
        timeout_seconds = 10,
        assertions = {
          { type = "status-code", expected = 200 },
          { type = "body-contains", expected = "healthy" },
        },
      })
    end
  end
  local catalog = {
    schema = execution.schemas.case_catalog,
    repository = { url = repository.url, commit_sha = repository.commit_sha },
    cases = catalog_cases,
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
      cli = inventory and {
        { argv_prefix = { "node", "cli.js", "reserve", "SKU-001", "3" } },
      } or { { argv_prefix = { "node", "cli.js" } } },
      http = options.cli_only == true and {} or {
        { origin = origin, methods = { "GET" },
          path_prefixes = { inventory and "/inventory/" or "/health" } },
      },
    },
    authority = { kind = "host-policy", ref = "fixtures/" .. fixture_name .. "-execution" },
    policy_revision = fixture_name .. "-execution-v1",
    evidence_ref = {
      kind = "signed-attestation", ref = "fixtures/" .. fixture_name .. "-execution-approval",
    },
    issued_at = "2026-07-22T00:00:00Z",
    expires_at = "2026-07-22T01:00:00Z",
    max_uses = 1,
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  assert(store:write(preauthorization_ref, preauthorization))

  local inventory_design_request
  if inventory then
    local design_input_root = artifact_root .. "/design/design-loop-inputs"
    local deterministic_cases = {
      schema = design_loop.schemas.deterministic_cases,
      cases = {},
    }
    local coverage_scope = {
      schema = design_loop.schemas.coverage_scope,
      subjects = {
        { id = "inventory:initial-state", kind = "requirement", priority = "P0",
          evidence_pointer = design_input_root .. "/inventory-initial-state.json" },
        { id = "inventory:reserve-three", kind = "requirement", priority = "P0",
          evidence_pointer = design_input_root .. "/inventory-reserve-three.json" },
        { id = "inventory:state-after-reserve", kind = "requirement", priority = "P0",
          evidence_pointer = design_input_root .. "/inventory-state-after-reserve.json" },
        { id = "inventory:over-reserve-rejected", kind = "requirement", priority = "P0",
          evidence_pointer = design_input_root .. "/inventory-over-reserve-rejected.json" },
        { id = "inventory:state-after-rejection", kind = "requirement", priority = "P0",
          evidence_pointer = design_input_root .. "/inventory-state-after-rejection.json" },
      },
    }
    local deterministic_ref = design_input_root .. "/deterministic-cases.json"
    local coverage_ref = design_input_root .. "/coverage-scope.json"
    assert(store:write(deterministic_ref, deterministic_cases))
    assert(store:write(coverage_ref, coverage_scope))
    inventory_design_request = {
      schema = design_loop.schemas.request,
      artifact_root = artifact_root .. "/design/design-loop",
      seed_cases_ref = {
        artifact_pointer = artifact_root .. "/ai-seed-cases.json",
        artifact_digest = "pending-workflow-seed-reference",
      },
      coverage_scope_ref = {
        artifact_pointer = coverage_ref,
        artifact_digest = design_loop.document_digest(coverage_scope),
      },
      deterministic_cases_ref = {
        artifact_pointer = deterministic_ref,
        artifact_digest = design_loop.document_digest(deterministic_cases),
      },
      max_rounds = 3,
      case_budget = 16,
      action_budget = 32,
      trace_id = trace_id,
      dedup_key = dedup_key,
    }
  end

  local request = {
    schema = workflow_qa.schemas.request,
    issue = { repository = repository.slug, number = 101, state = "open", labels = { "fkst-qa" } },
    run_id = run_id,
    repository = copy(repository),
    artifact_root = artifact_root,
    state_ref = artifact_root .. "/workflow-state.json",
    proposed_cases = inventory and {
      {
        id = "inventory-initial-state", module_id = "inventory", priority = "P0",
        title = "Initial inventory state",
        objective = "Verify the durable initial inventory state for SKU-001.", case_kind = "api",
        actions = { { action = "http", target = "/inventory/SKU-001", expected = "HTTP 200" } },
        expected_observable = "SKU-001 has on-hand 5, reserved 0, and available 5.",
        coverage_subject_ids = { "inventory:initial-state" }, review_status = "executable",
      },
      {
        id = "inventory-reserve-three", module_id = "inventory", priority = "P0",
        title = "Reserve three units", objective = "Reserve three available SKU-001 units.", case_kind = "cli",
        actions = { { action = "cli", target = "node cli.js reserve SKU-001 3", expected = "exit 0" } },
        expected_observable = "SKU-001 has reserved 3 and available 2.",
        coverage_subject_ids = { "inventory:reserve-three" }, review_status = "executable",
      },
      {
        id = "inventory-state-after-reserve", module_id = "inventory", priority = "P0",
        title = "Inventory after reservation", objective = "Observe the successful reservation.", case_kind = "api",
        actions = { { action = "http", target = "/inventory/SKU-001", expected = "HTTP 200" } },
        expected_observable = "SKU-001 has on-hand 5, reserved 3, and available 2.",
        coverage_subject_ids = { "inventory:state-after-reserve" }, review_status = "executable",
      },
      {
        id = "inventory-over-reserve-rejected", module_id = "inventory", priority = "P0",
        title = "Reject over-reservation", objective = "Reject reserving more than available.", case_kind = "cli",
        actions = { { action = "cli", target = "node cli.js reserve SKU-001 3", expected = "exit 4" } },
        expected_observable = "The reservation is rejected without mutation.",
        coverage_subject_ids = { "inventory:over-reserve-rejected" }, review_status = "executable",
      },
      {
        id = "inventory-state-after-rejection", module_id = "inventory", priority = "P0",
        title = "Inventory after rejection", objective = "Observe unchanged state after rejection.", case_kind = "api",
        actions = { { action = "http", target = "/inventory/SKU-001", expected = "HTTP 200" } },
        expected_observable = "SKU-001 remains on-hand 5, reserved 3, and available 2.",
        coverage_subject_ids = { "inventory:state-after-rejection" }, review_status = "executable",
      },
    } or {
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
        baseline_commit_sha = repository.commit_sha,
        workspace_ref = { kind = "workspace", ref = workspace_root },
        approval_ref = analysis_approval_ref,
        approval_sha256 = store:digest(analysis_approval_ref.ref),
      },
      inputs = {},
      artifact_root = artifact_root .. "/analysis",
      source_ref = { kind = "workflow-qa", ref = run_id },
      trace_id = trace_id,
      dedup_key = dedup_key,
    },
    design_module_start = {
      schema = "module-testing-pipeline.module-start.v1",
      module = inventory and "inventory" or "service",
      backend = "fkst-native",
      no_browser = false,
      dry_run = false,
      artifact_root = artifact_root .. "/design",
      source_ref = { kind = "workflow-qa", ref = run_id },
      trace_id = trace_id,
      dedup_key = dedup_key,
      ui_loop = {
        allowed_origins = { origin },
        mutation_policy = inventory and "host-approved" or "read-only",
        cdp_readiness_ref = "canonical-cdp-ready",
      },
      module_discovery = {
        schema = "testing-runner.module-discovery.v1",
        observations = {
          {
            id = inventory and "inventory" or "service",
            name = inventory and "Inventory" or "Canonical Service", entry_url = base_url,
            visible_label = inventory and "Inventory" or "Canonical Service",
            discovery_source = "navigation", confidence = "high",
            evidence_pointer = artifact_root .. "/design/evidence/" .. (inventory and "inventory" or "service") .. ".json",
          },
        },
        limitations = {
          inventory and "The inventory fixture exposes one local inventory surface."
            or "The canonical fixture exposes one local service surface.",
        },
      },
      ai_design_loop_request = inventory_design_request,
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
      channel = options.publication_channel or (durable_enabled and "filesystem-dry-run-v1" or nil),
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
    project_root = supervisor_project_root,
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
    effect_counter_path = effect_counter_path,
    completed_replay_failpoint = completed_replay_failpoint,
    crash_barrier = crash_barrier,
    runtime_pep_denial = runtime_pep_denial,
    pep_mutate_plan_binding = options.pep_mutate_plan_binding == true,
    fixture_name = fixture_name,
    fixture_source_root = absolute("examples/generic-host/fixtures/" .. fixture_name),
    use_local_qa_departments = inventory,
    local_qa_department_calls = {},
    temp_root_prefix = "/tmp/fkst-generic-host-" .. run_prefix,
    artifact_root_prefix = project_root .. "/.testing/runs/" .. run_prefix,
  }, Context)
  context.environment_runtime = context:_environment_runtime()
  context.workflow_runtime = context:_workflow_runtime()
  context.module_loop_runtime = context:_module_loop_runtime()
  context.testing_design_runtime = context:_testing_design_runtime()
  context.structured_runtime = context:_structured_runtime()
  context.publication_runtime = context:_publication_runtime()
  context.generic_host_runtime = context:_generic_host_runtime()
  local durable_root = options.durable_root
  if durable_root == nil and options.durable == true then durable_root = temp_root .. "/framework-durable" end
  if durable_root ~= nil then
    local durable = require("host_durable_workflow_qa")
    durable.initialize(context, durable_root)
    context.runtime_config_ref = ".testing/generic-host-runtime.json"
    write_file(context.project_root .. "/" .. context.runtime_config_ref, json_codec.encode({
      schema = "generic-host.runtime-config.v1",
      project_root = context.project_root,
    }) .. "\n")
    if options.prepare_execution_grant_pending ~= false then
      local prepared_context = durable.load(context.project_root, durable_root, context.run_id)
      require("test_support.host_workflow_qa_supervisor").prepare(prepared_context, context.project_root)
    end
  end
  return context
end

M.copy = copy
M.equal = equal
M.sha256_bytes = sha256_bytes

return M
