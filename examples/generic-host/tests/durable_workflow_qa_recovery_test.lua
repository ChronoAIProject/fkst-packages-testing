local durable = require("host_durable_workflow_qa")
local support = require("host_canonical_workflow_qa")
local process = require("test_support.durable_workflow_qa_process")
local supervisor_support = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local assert_log_markers = process.assert_log_markers
local effect_count = process.effect_count
local http_effect_count = process.http_effect_count
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
    authorizations = #context.records:list("testing-runner/cli-effect-authorizations"),
    consumptions = #context.records:list("testing-runner/cli-effect-consumptions"),
    target_effects = #context.records:list("testing-runner/target-effects"),
    terminal_records = #context.records:list("generic-host/terminal"),
  }
end

local function assert_counts_equal(left, right)
  for key, value in pairs(left) do t.eq(right[key], value) end
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
  t.eq(barrier.replay_status, "completed")
  t.eq(effect_count(context), 1)
  t.eq(http_effect_count(context), context.expected_case_count == 2 and 1 or 0)
  t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), context.expected_case_count)
  t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), context.expected_case_count)
  t.eq(#recovered.records:list("testing-runner/target-effects"), context.expected_case_count)
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
  t.eq(#recovered.records:list("testing-runner/target-effects"), context.expected_case_count)
  t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), context.expected_case_count)
  t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), context.expected_case_count)
  local recovery = recovered.records:read("generic-host/recovery/execution")
  if context.completed_replay_failpoint ~= nil then t.eq(recovery.replayed, true) else t.eq(recovery, nil) end

  local terminal = recovered:terminal_record()
  t.eq(terminal.status, "passed")
  t.eq(terminal.counts.planned, context.expected_case_count)
  t.eq(terminal.counts.executed, context.expected_case_count)
  t.eq(terminal.counts.passed, context.expected_case_count)
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
  local result = process.exec({ "node", "-e", script, path, mode })
  if result.exit_code ~= 0 then error("generic-host recovery test: durable mutation failed: " .. mode) end
end

local function replay_record_path(context, recovered)
  local entries = recovered.records:list("testing-runner/replay")
  t.eq(#entries, 1)
  return context.durable_run_root .. "/records/" .. entries[1].key .. ".json"
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

local function http_effect_journal_crash_case(name, expected_journal_status, expected_terminal_status)
  with_context({
    http_only = true, count_effect = true, durable = true, crash_barrier = name,
  }, function(context, live_pids)
    local pid, stdout_path, stderr_path = start_supervisor(context, "crash-" .. name, name, live_pids)
    local barrier_path = context.durable_run_root .. "/records/generic-host/barriers/" .. name .. ".json"
    if not wait_for_path(barrier_path, 180) then
      error("generic-host HTTP journal crash barrier was not reached: " .. name
        .. "\nstdout=" .. tostring(read_file(stdout_path))
        .. "\nstderr=" .. tostring(read_file(stderr_path)))
    end
    local at_barrier = durable.load(context.project_root, context.durable_root, context.run_id)
    local journals = at_barrier.records:list("testing-runner/effect-executions")
    t.eq(#journals, 1)
    t.eq(journals[1].value.status, expected_journal_status)
    t.eq(http_effect_count(context), 1)
    t.eq(#at_barrier.records:list("testing-runner/target-effects"), 0)
    local owners = at_barrier.records:list("testing-runner/replay-owners")
    t.eq(#owners, 1)
    t.eq(owners[1].value.generation, 1)

    local replay = at_barrier.records:list("testing-runner/replay")[1].value
    local duplicate = at_barrier.structured_runtime.replay_guard(support.copy(replay.binding))
    t.eq(duplicate.status, "in-progress")
    local while_live = durable.load(context.project_root, context.durable_root, context.run_id)
    t.eq(while_live:terminal_record(), nil)
    t.eq(http_effect_count(context), 1)
    t.eq(#while_live.records:list("testing-runner/target-effects"), 0)
    t.eq(while_live.records:list("testing-runner/replay-owners")[1].value.generation, 1)
    process.stop_live(pid, live_pids)

    local replacement, replacement_stdout, replacement_stderr = start_supervisor(
      context, "replacement-" .. name, false, live_pids)
    if not wait_for_terminal(context) then
      error("generic-host HTTP journal replacement did not reach terminal: " .. name
        .. "\nstdout=" .. tostring(read_file(replacement_stdout))
        .. "\nstderr=" .. tostring(read_file(replacement_stderr)))
    end
    process.stop_live(replacement, live_pids)
    local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
    local terminal = recovered:terminal_record()
    t.eq(terminal.status, expected_terminal_status)
    local recovered_owners = recovered.records:list("testing-runner/replay-owners")
    t.eq(#recovered_owners, 1)
    t.eq(recovered_owners[1].value.generation, 2)
    t.eq(http_effect_count(context), 1)
    t.eq(#recovered.records:list("testing-runner/target-effects"),
      expected_terminal_status == "passed" and 1 or 0)
    local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
    t.eq(cleanup.status, "complete")
    t.eq(#cleanup.remaining_resources, 0)
    local publication = recovered.store:load(terminal.aggregate_publication_receipt_ref).value
    t.eq(publication.status, "published")
    t.eq(publication.stage, "aggregate-report")
    t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
  end)
end

return {
  test_durable_workflow_qa_recovers_completed_cli_and_http_without_repeating_effects = function()
    with_context({
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
      local execution_root = context.request.structured_execution.artifact_root
      local case_results = recovered.store:load(execution_root .. "/case-results.json").value
      local health_evidence_ref
      for _, case_result in ipairs(case_results.cases or {}) do
        if case_result.case_id == "health" then health_evidence_ref = case_result.evidence_ref end
      end
      local health_evidence = recovered.store:load(health_evidence_ref).value
      t.eq(health_evidence.authorization_receipt_path,
        execution_root .. "/authorization/health.json")
      local http_receipt = recovered.store:load(health_evidence.authorization_receipt_path).value
      t.eq(http_receipt.decision, "allow")
      t.eq(http_receipt.reason_code, "authorized")
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
      t.eq(before.authorizations, 2)
      t.eq(before.consumptions, 2)
      t.eq(before.target_effects, 2)
      t.eq(before.terminal_records, 1)
      t.eq(effect_count(context), 1)
      t.eq(http_effect_count(context), 1)
      local kinds = {}
      for _, entry in ipairs(recovered.records:list("testing-runner/target-effects")) do
        kinds[entry.value.binding.action_envelope.effect.kind] = true
      end
      t.eq(kinds.cli, true)
      t.eq(kinds.http, true)
    end)
  end,

  test_durable_http_started_journal_blocks_without_repeating_request = function()
    http_effect_journal_crash_case(
      "http-after-response-before-journal-complete", "started", "blocked")
  end,

  test_durable_http_completed_journal_reuses_result_without_repeating_request = function()
    http_effect_journal_crash_case(
      "http-after-journal-complete-before-return", "completed", "passed")
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
      t.eq(terminal.counts.executed, 0)
      t.eq(terminal.counts.blocked, 1)
      local authorization = recovered.store:load(
        context.request.structured_execution.artifact_root .. "/authorization/cli-version.json")
      t.eq(authorization.value.schema, "testing-effect-authorization-receipt.v1")
      t.eq(authorization.value.decision, "deny")
      t.eq(authorization.value.reason_code, "profile-policy-denied")
      t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), 0)
      t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), 0)
      t.eq(#recovered.records:list("testing-runner/target-effects"), 0)
      t.eq(effect_count(context), 0)
      t.eq(http_effect_count(context), 0)
      local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      local publication = recovered.store:load(terminal.aggregate_publication_receipt_ref).value
      t.eq(publication.status, "published")
      t.eq(publication.stage, "aggregate-report")
      t.eq(publication.channel, "filesystem-dry-run-v1")
      local released = recovered:_fixture_effect("fixture-release-status", {
        run_id = context.run_id, artifact_root = context.artifact_root,
      })
      t.eq(released.process_group_absent, true)
      t.eq(released.listeners_closed, true)
      t.eq(released.workspace_absent, true)
      assert_log_markers(stdout_path, "production PEP denial supervisor", {
        "dept=generic-host.workflow_qa_supervisor ",
        "dept=testing-runner.run_structured_execution ",
        "dept=generic-host.workflow_qa_terminal ",
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
      t.eq(http_effect_count(context), 0)
    end)
  end,

  test_durable_workflow_qa_http_pep_plan_digest_mutation_denies_without_target_effect = function()
    with_context({
      http_only = true,
      count_effect = true,
      durable = true,
      runtime_pep_mutate_plan_digest = true,
    }, function(context, live_pids)
      local pid, stdout_path, stderr_path = start_supervisor(
        context, "production-http-plan-mutation", false, live_pids)
      if not wait_for_terminal(context) then
        error("generic-host recovery test: HTTP PEP mutation did not reach terminal "
          .. state_diagnostic(context) .. "\nstdout=" .. tostring(read_file(stdout_path))
          .. "\nstderr=" .. tostring(read_file(stderr_path)))
      end
      stop_live(pid, live_pids)
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      local terminal = recovered:terminal_record()
      t.eq(terminal.status, "blocked")
      t.eq(terminal.counts.executed, 0)
      t.eq(terminal.counts.blocked, 1)
      local authorization = recovered.store:load(
        context.request.structured_execution.artifact_root .. "/authorization/health.json")
      t.eq(authorization.value.schema, "testing-effect-authorization-receipt.v1")
      t.eq(authorization.value.decision, "deny")
      t.eq(authorization.value.reason_code, "foreign-binding")
      t.eq(#recovered.records:list("testing-runner/cli-effect-authorizations"), 0)
      t.eq(#recovered.records:list("testing-runner/cli-effect-consumptions"), 0)
      t.eq(#recovered.records:list("testing-runner/target-effects"), 0)
      t.eq(effect_count(context), 0)
      t.eq(http_effect_count(context), 0)
      local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      local publication = recovered.store:load(terminal.aggregate_publication_receipt_ref).value
      t.eq(publication.status, "published")
      t.eq(publication.stage, "aggregate-report")
      t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
      local before = record_counts(recovered)
      t.eq(before.replay_claims, 1)
      t.eq(before.authorizations, 0)
      t.eq(before.consumptions, 0)
      t.eq(before.target_effects, 0)
      t.eq(before.terminal_records, 1)

      local noop_pid, noop_stdout, noop_stderr = start_supervisor(
        context, "production-http-plan-mutation-noop", false, live_pids)
      if not wait_for_noop(context, "production-http-plan-mutation-noop") then
        error("generic-host recovery test: HTTP PEP mutation terminal restart was not a no-op\nstdout="
          .. tostring(read_file(noop_stdout)) .. "\nstderr=" .. tostring(read_file(noop_stderr)))
      end
      stop_live(noop_pid, live_pids)
      local after = durable.load(context.project_root, context.durable_root, context.run_id)
      assert_counts_equal(before, record_counts(after))
      t.eq(effect_count(context), 0)
      t.eq(http_effect_count(context), 0)
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
