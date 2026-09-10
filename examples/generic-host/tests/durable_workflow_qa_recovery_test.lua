local durable = require("host_durable_workflow_qa")
local lineage = require("contract.execution_authorization_lineage")
local support = require("host_canonical_workflow_qa")
local process = require("test_support.durable_workflow_qa_process")
local supervisor_support = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local assert_log_markers = process.assert_log_markers
local effect_count = process.effect_count
local read_file = process.read_file
local start_supervisor = process.start_supervisor
local stop_live = process.stop_live
local wait_for_child_text = process.wait_for_child_text
local wait_for_path = process.wait_for_path
local wait_for_terminal = process.wait_for_terminal
local wait_for_text = process.wait_for_text
local wait_for_noop = process.wait_for_noop
local with_context = process.with_context

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

local function assert_authorization_lineage(context, recovered)
  local artifacts, expected = recovered:authorization_lineage_evidence()
  for name, suffix in pairs(lineage.paths) do
    local ref = context.artifact_root .. "/" .. suffix
    local artifact = recovered.store:load(ref)
    t.is_true(type(artifact) == "table" and type(artifact.value) == "table")
    t.eq(artifacts[name].ref, ref)
    t.eq(artifacts[name].sha256, artifact.digest)
    t.eq(artifact.raw:sub(-1), "}")
    t.is_true(artifact.raw:find('"claim_id"', 1, true) == nil)
    t.is_true(artifact.raw:find('"fence_id"', 1, true) == nil)
    t.is_true(artifact.raw:find('"mac"', 1, true) == nil)
    t.is_true(artifact.raw:find(context.workspace_root, 1, true) == nil)
    t.is_true(artifact.value.authorization_capability == false)
    t.is_true(artifact.value.reusable == false)
    t.eq(artifact.value.source_max_uses, 1)
  end
  local index_ref = context.artifact_root .. "/authorization-lineage/index.json"
  local index = recovered.store:load(index_ref)
  t.is_true(type(index) == "table" and type(index.value) == "table")
  t.eq(lineage.validate_lineage_index(index.value, artifacts, expected), index.value)
  t.eq(index.raw:sub(-1), "}")
  t.eq(index.value.lineage_complete, true)
  t.eq(#recovered.records:list("generic-host/profile-approval"), 1)
  t.eq(#recovered.records:list("generic-host/preauthorization"), 1)
  t.eq(#recovered.records:list("testing-runner/grant-verifications"), 1)
  t.eq(#recovered.records:list("testing-runner/replay"), 1)
  local profile_claim = recovered.records:list("generic-host/profile-approval")[1].value
  local preauthorization_claim = recovered.records:list("generic-host/preauthorization")[1].value
  local replay = recovered.records:list("testing-runner/replay")[1]
  for _, private_id in ipairs({
    profile_claim.claim_id, preauthorization_claim.claim_id, replay.value.claim_id,
  }) do
    t.is_true(type(private_id) == "string" and private_id:sub(1, 14) == "private-claim-")
    t.is_true(private_id ~= context.run_id .. "-profile-claim")
    t.is_true(private_id ~= context.run_id .. "-preauthorization")
    t.is_true(private_id ~= context.run_id .. "-execution-claim")
    for _, artifact in pairs(artifacts) do
      t.is_true(recovered.store:load(artifact.ref).raw:find(private_id, 1, true) == nil)
    end
  end
  local public_guess = artifacts.execution_claim.value.receipt_id
  local rejected = recovered.records:complete_replay(
    replay.key, public_guess, replay.value.completion)
  t.eq(rejected.completed, false)
  rejected = recovered.records:complete_replay(
    replay.key, artifacts.execution_claim.value.claim_fingerprint_sha256,
    replay.value.completion)
  t.eq(rejected.completed, false)
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
  local execution = recovered.store:load(barrier.result_ref).value
  t.eq(barrier.test_plan_ref, execution.test_plan_path)
  t.eq(barrier.test_plan_sha256, recovered.store:digest(barrier.test_plan_ref))
  t.eq(barrier.case_results_ref, execution.case_results_path)
  t.eq(barrier.case_results_sha256, recovered.store:digest(barrier.case_results_ref))
  t.eq(barrier.replay_status, "completed")
  t.eq(effect_count(context), 1)
  t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), 1)
  t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), 1)
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
    "dept=local-qa-host-adapter.execution_grant ",
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
  t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), 1)
  t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), 1)
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
  t.eq(released.worker_environment_absent, true)
  t.eq(#recovered.records:list("generic-host/terminal"), 1)
  assert_authorization_lineage(context, recovered)
  return recovered
end

local function mutate_record(path, mode)
  local script = table.concat({
    "const fs=require('fs'),path=process.argv[1],mode=process.argv[2],value=JSON.parse(fs.readFileSync(path,'utf8'));",
    "if(mode==='request')value.issue.number+=1;",
    "else if(mode==='authorization')value.authorization.profile_sha256='0'.repeat(64);",
    "else if(mode==='profile-claim')value.binding.profile_sha256='0'.repeat(64);",
    "else if(mode==='execution')value.binding.trace_id+='-mutated';",
    "else process.exit(51);",
    "const next=path+'.mutation-'+process.pid;fs.writeFileSync(next,JSON.stringify(value)+'\\n',{flag:'wx'});fs.renameSync(next,path);",
  })
  local result = process.exec({ "node", "-e", script, path, mode })
  if result.exit_code ~= 0 then error("generic-host recovery test: durable mutation failed: " .. mode) end
end

local function replay_record_path(context, recovered)
  local entries = recovered.records:list("testing-runner/replay")
  t.eq(#entries, 1)
  return context.durable_run_root .. "/records/" .. entries[1].key .. ".json"
end

local function substitute_completed_execution_plan(context, recovered)
  local replay = recovered.records:list("testing-runner/replay")[1].value
  local script = table.concat({
    "const crypto=require('crypto'),fs=require('fs'),path=require('path');",
    "const root=process.argv[1],replayPath=process.argv[2],resultRef=process.argv[3];",
    "const sha=v=>crypto.createHash('sha256').update(v).digest('hex');",
    "const file=ref=>path.join(root,'artifacts',sha(ref)+'.json');",
    "const read=ref=>JSON.parse(fs.readFileSync(file(ref),'utf8'));",
    "const write=(ref,value)=>{const target=file(ref),record=read(ref),body=JSON.stringify(value)+'\\n';record.body=body;record.digest=sha(body);fs.writeFileSync(target,JSON.stringify(record)+'\\n');return record.digest};",
    "const executionRecord=read(resultRef),execution=JSON.parse(executionRecord.body);",
    "const planRecord=read(execution.test_plan_path),plan=JSON.parse(planRecord.body);plan.foreign_plan_identity='substituted';",
    "const planDigest=write(execution.test_plan_path,plan);",
    "const manifestRecord=read(execution.evidence_manifest_path),manifest=JSON.parse(manifestRecord.body);manifest.plan_sha256=planDigest;",
    "const manifestDigest=write(execution.evidence_manifest_path,manifest);",
    "const setRecord=read(execution.case_result_set_path),set=JSON.parse(setRecord.body);set.plan_sha256=planDigest;",
    "for(const item of set.cases||[])item.plan_sha256=planDigest;",
    "set.evidence_manifest_ref.sha256=manifestDigest;set.evidence_manifest_artifact_sha256=manifestDigest;",
    "const setDigest=write(execution.case_result_set_path,set);",
    "execution.plan_sha256=planDigest;execution.case_result_set_artifact_sha256=setDigest;execution.evidence_manifest_artifact_sha256=manifestDigest;",
    "const resultDigest=write(resultRef,execution);",
    "const claim=JSON.parse(fs.readFileSync(replayPath,'utf8'));claim.result_sha256=resultDigest;claim.completion.result_sha256=resultDigest;",
    "fs.writeFileSync(replayPath,JSON.stringify(claim)+'\\n');",
  })
  local result = process.exec({
    "node", "-e", script, context.durable_run_root,
    replay_record_path(context, recovered), replay.result_ref,
  })
  if result.exit_code ~= 0 then error("generic-host recovery test: execution Plan substitution failed") end
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
    elseif mode == "profile-claim" then
      mutate_record(context.durable_run_root .. "/records/generic-host/profile-approval/"
        .. context.run_id .. ".json", mode)
    else
      local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      execution_request = support.copy(state.pending_actions[1].payload)
      mutate_record(replay_record_path(context, recovered), mode)
    end

    local label = mode .. "-second"
    local pid, stdout_path, stderr_path = start_supervisor(context, label, false, live_pids)
    local observed_path = expected_stream == "stdout" and stdout_path or stderr_path
    local child_logs = context.host_root .. "/framework-runtime-" .. label .. "/logs/framework-child"
    local observed
    if mode == "execution" then
      observed = wait_for_child_text(
        child_logs, "testing-runner.run_structured_execution-", expected_fragment, 45)
    elseif mode == "profile-claim" then
      observed = wait_for_child_text(
        child_logs, "environment-factory.finalize-", expected_fragment, 45)
    else
      observed = wait_for_text(observed_path, expected_fragment, 45)
    end
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
        "dept=local-qa-host-adapter.terminal ",
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

  test_durable_workflow_qa_rejects_foreign_plan_during_result_recovery_and_lineage_projection = function()
    with_context({
      cli_only = true,
      count_effect = true,
      durable = true,
      arm_completed_replay_failpoint = true,
    }, function(context, live_pids)
      local recovered = run_to_barrier(context, live_pids, "foreign-plan-first")
      substitute_completed_execution_plan(context, recovered)
      recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local claim = recovered.records:list("testing-runner/replay")[1].value
      local binding = claim.binding
      local summary = recovered.structured_runtime.load_result({
        artifact_root = binding.artifact_root,
        result_ref = claim.result_ref,
        result_sha256 = claim.result_sha256,
        operation_id = binding.operation_id,
        repository = support.copy(binding.repository),
        environment_receipt_sha256 = binding.environment_receipt_sha256,
        trace_id = binding.trace_id,
        dedup_key = binding.dedup_key,
      })
      t.eq(summary, nil)
      local ok, failure = pcall(function() recovered:authorization_lineage_evidence() end)
      t.eq(ok, false)
      t.is_true(tostring(failure):find("completion Plan binding differs", 1, true) ~= nil)
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

  test_durable_workflow_qa_node_runtime_recovers_legacy_preauthorization_claim = function()
    with_context({
      cli_only = true,
      count_effect = true,
      durable = true,
      prepare_execution_grant_pending = true,
    }, function(context, live_pids)
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      t.eq(state.phase, "execution-grant-pending")
      t.eq(state.pending_actions[1].queue, "workflow_qa_execution_grant_request")
      local request = support.copy(state.pending_actions[1].payload)
      local preauthorization = recovered.store:load(request.preauthorization_ref)
      local claim_request = {
        authorization_id = preauthorization.value.authorization_id,
        preauthorization_ref = request.preauthorization_ref,
        preauthorization_sha256 = request.preauthorization_sha256,
        repository = support.copy(request.repository),
        plan_ref = request.plan_ref,
        plan_sha256 = request.plan_sha256,
        environment_receipt_ref = request.environment_receipt_ref,
        environment_receipt_sha256 = request.environment_receipt_sha256,
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
      }
      local private_claim_id = recovered:_private_claim_id("legacy-preauthorization")
      local legacy_binding = support.copy(claim_request)
      legacy_binding.preauthorization_ref = nil
      legacy_binding.plan_ref = nil
      legacy_binding.environment_receipt_ref = nil
      local key = "generic-host/preauthorization/" .. recovered:_key(claim_request.authorization_id)
      local stored = recovered.records:claim(key, {
        binding = legacy_binding,
        claim_id = private_claim_id,
        claimed_at = recovered.execution_authorization_now,
      })
      t.eq(stored.claimed, true)
      t.eq(#recovered.records:list("testing-runner/grant-verifications"), 0)

      local replayed = recovered:_fixture_effect("host-claim-preauthorization", claim_request)
      t.eq(replayed.status, "claimed")
      t.eq(replayed.replayed, true)
      t.eq(replayed.claim_id, private_claim_id)
      t.eq(#recovered.records:list("generic-host/preauthorization"), 1)
      t.eq(#recovered.records:list("testing-runner/grant-verifications"), 0)

      local substituted = support.copy(claim_request)
      substituted.plan_ref = context.artifact_root .. "/execution/foreign-plan.json"
      local blocked = recovered:_fixture_effect("host-claim-preauthorization", substituted)
      t.eq(blocked.status, "blocked")
      t.eq(#recovered.records:list("generic-host/preauthorization"), 1)

      local pid, stdout_path, stderr_path = start_supervisor(
        context, "legacy-preauthorization-recovery", false, live_pids)
      if not wait_for_terminal(context) then
        error("generic-host recovery test: legacy Preauthorization recovery did not reach terminal "
          .. state_diagnostic(context) .. "\nstdout=" .. tostring(read_file(stdout_path))
          .. "\nstderr=" .. tostring(read_file(stderr_path)))
      end
      stop_live(pid, live_pids)
      local terminal = assert_terminal(context)
      t.eq(#terminal.records:list("generic-host/preauthorization"), 1)
      t.eq(#terminal.records:list("testing-runner/grant-verifications"), 1)
      t.eq(terminal.records:list("generic-host/preauthorization")[1].value.claim_id,
        private_claim_id)
    end)
  end,

  test_durable_workflow_qa_production_pep_denial_reaches_blocked_terminal_without_cli_effect = function()
    with_context({
      cli_only = true,
      count_effect = true,
      durable = true,
      runtime_pep_deny_reason = "profile-policy-denied",
    }, function(context, live_pids)
      local pid, stdout_path, stderr_path = start_supervisor(
        context, "production-pep-denial", false, live_pids)
      if not wait_for_terminal(context) then
        error("generic-host recovery test: production PEP denial did not reach terminal "
          .. state_diagnostic(context) .. "\nstdout=" .. tostring(read_file(stdout_path))
          .. "\nstderr=" .. tostring(read_file(stderr_path)))
      end
      stop_live(pid, live_pids)
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
      t.eq(state.phase, "terminal")
      t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
      local terminal = recovered:terminal_record()
      t.eq(terminal.status, "blocked")
      t.eq(terminal.counts.executed, 1)
      t.eq(terminal.counts.error, 1)
      t.eq(terminal.counts.blocked, 0)
      local authorization = recovered.store:load(
        context.request.structured_execution.artifact_root .. "/authorization/cli-version.json")
      t.eq(authorization.value.schema, "testing-effect-authorization-receipt.v1")
      t.eq(authorization.value.decision, "deny")
      t.eq(authorization.value.reason_code, "profile-policy-denied")
      t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), 0)
      t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), 0)
      t.eq(#recovered.records:list("testing-runner/target-effects"), 0)
      t.eq(effect_count(context), 0)
      local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      local publication = recovered.store:load(terminal.aggregate_publication_receipt_ref).value
      t.eq(publication.status, "published")
      t.eq(publication.stage, "aggregate-report")
      assert_log_markers(stdout_path, "production PEP denial supervisor", {
        "dept=generic-host.workflow_qa_supervisor ",
        "dept=testing-runner.run_structured_execution ",
        "dept=local-qa-host-adapter.terminal ",
      })
      local before = record_counts(recovered)
      t.eq(before.replay_claims, 1)
      t.eq(before.target_effects, 0)
      t.eq(before.terminal_records, 1)

      local noop_pid, noop_stdout, noop_stderr = start_supervisor(
        context, "production-pep-denial-noop", false, live_pids)
      if not wait_for_noop(context, "production-pep-denial-noop") then
        error("generic-host recovery test: blocked terminal restart was not a no-op\nstdout="
          .. tostring(read_file(noop_stdout)) .. "\nstderr=" .. tostring(read_file(noop_stderr)))
      end
      stop_live(noop_pid, live_pids)
      local after = durable.load(context.project_root, context.durable_root, context.run_id)
      assert_counts_equal(before, record_counts(after))
      t.eq(#after.records:list("testing-runner/cli-effect-authorizations"), 0)
      t.eq(#after.records:list("testing-runner/cli-effect-consumptions"), 0)
      t.eq(effect_count(context), 0)
    end)
  end,

  test_durable_workflow_qa_request_binding_mutation_fails_closed = function()
    mutation_case("request", "foreign-state", "stdout")
  end,

  test_durable_workflow_qa_authorization_binding_mutation_fails_closed = function()
    mutation_case("authorization", "authorization-binding-changed", "stdout")
  end,

  test_durable_workflow_qa_profile_claim_binding_mutation_fails_closed = function()
    mutation_case("profile-claim", "environment authorization approval claim is unavailable", "stderr")
  end,

  test_durable_workflow_qa_execution_binding_mutation_fails_closed = function()
    mutation_case("execution", "testing-runner dept=run_structured_execution tag=BLOCKED", "stdout")
  end,
}
