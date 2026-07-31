local durable = require("host_durable_workflow_qa")
local process = require("test_support.durable_workflow_qa_process")
local support = require("host_canonical_workflow_qa")
local t = fkst.test

local CASES = {
  { name = "workflow-before-state-save", version = 11, phase = "execution-grant-pending",
    queue = "workflow_qa_execution_grant_request", execution_effects = 0 },
  { name = "workflow-after-state-save", version = 12, phase = "structured-execution-pending",
    queue = "testing-runner.structured_execution_request", execution_effects = 0 },
  { name = "cleanup-after-effect", version = 15, phase = "cleanup-pending",
    queue = "environment-factory.environment_finalize", execution_effects = 1 },
  { name = "publication-after-effect", version = 17, phase = "publication-pending",
    queue = "test-publication.qa_finalize_request", execution_effects = 1 },
}

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

local function durable_file_counts(context)
  local script = table.concat({
    "const fs=require('fs'),path=require('path'),root=process.argv[1];",
    "function count(dir){let total=0;try{for(const item of fs.readdirSync(dir,{withFileTypes:true})){",
    "const target=path.join(dir,item.name);total+=item.isDirectory()?count(target):",
    "(item.name.endsWith(\".json\")?1:0)}}catch(error){if(error.code!==\"ENOENT\")throw error}return total}",
    "const artifacts=path.join(root,'artifacts'),paths=[];try{for(const name of fs.readdirSync(artifacts)){",
    "if(name.endsWith('.json'))paths.push(JSON.parse(fs.readFileSync(path.join(artifacts,name),'utf8')).path)}}",
    "catch(error){if(error.code!==\"ENOENT\")throw error}",
    "const artifactRoot=process.argv[2],cleanup=artifactRoot+'/cleanup-receipt-complete.json';",
    "const publication=artifactRoot+'/publication-receipts/aggregate-report-';",
    "process.stdout.write([count(path.join(root,'records')),count(artifacts),",
    "paths.filter(value=>value===cleanup).length,paths.filter(value=>value.startsWith(publication)).length].join(' '));",
  })
  local output = process.exec({
    "node", "-e", script, context.durable_run_root, context.artifact_root,
  }).stdout
  local records, artifacts, cleanup_receipts, aggregate_receipts =
    output:match("(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
  return {
    records = tonumber(records), artifacts = tonumber(artifacts),
    cleanup_receipts = tonumber(cleanup_receipts),
    aggregate_receipts = tonumber(aggregate_receipts),
  }
end

local function assert_equal_counts(expected, actual)
  for key, value in pairs(expected) do t.eq(actual[key], value) end
end

local function matching_effect(context, prefix, predicate)
  local matched
  for _, entry in ipairs(context.records:list(prefix)) do
    if predicate(entry.value) then
      t.eq(matched, nil)
      matched = entry
    end
  end
  t.is_true(matched ~= nil)
  return matched
end

local function cleanup_effect(value)
  return type(value.binding) == "table" and type(value.binding.cleanup_ref) == "table"
    and value.binding.cleanup_ref.kind == "port-lease"
end

local function aggregate_effect(value)
  return type(value.binding) == "table" and value.binding.stage == "aggregate-report"
end

local function assert_barrier(context, case)
  local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  t.eq(state.schema, "workflow-qa.run-state.v2")
  t.eq(state.version, case.version)
  t.eq(state.phase, case.phase)
  t.eq(state.active_checkpoint and state.active_checkpoint.stage or nil, nil)
  t.eq(#state.pending_actions, 1)
  t.eq(state.pending_actions[1].queue, case.queue)
  t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 1)
  t.eq(#durable.list_indexed_runs(context.project_root, context.durable_root, 10), 1)
  t.eq(#recovered.records:list("workflow-qa/requests"), 1)
  t.eq(#recovered.records:list("generic-host/profile-approval"), 1)
  t.eq(#recovered.records:list("generic-host/preauthorization"), 1)
  t.eq(#recovered.records:list("testing-runner/target-effects"), case.execution_effects)
  t.eq(recovered:terminal_record(), nil)

  local barrier = recovered.records:read("generic-host/barriers/" .. case.name)
  t.eq(barrier.schema, "generic-host.crash-barrier.v1")
  t.eq(barrier.run_id, context.run_id)
  t.eq(barrier.name, case.name)
  t.eq(barrier.token_sha256, recovered.records:digest(context.crash_barrier.token))
  if case.name == "workflow-before-state-save" then
    t.eq(barrier.details.expected_version, 11)
    t.eq(barrier.details.next_version, 12)
    t.eq(barrier.details.next_phase, "structured-execution-pending")
  elseif case.name == "workflow-after-state-save" then
    t.eq(barrier.details.expected_version, 11)
    t.eq(barrier.details.saved_version, 12)
    t.eq(barrier.details.saved_phase, "structured-execution-pending")
  elseif case.name == "cleanup-after-effect" then
    t.eq(barrier.details.cleanup_ref.kind, "port-lease")
    t.eq(barrier.details.status, "cleaned")
  else
    t.eq(barrier.details.stage, "aggregate-report")
    t.eq(barrier.details.attempt, 1)
  end

  local cleanup_ref = context.artifact_root .. "/cleanup-receipt-complete.json"
  local aggregate_receipt_ref = context.artifact_root .. "/publication-receipts/aggregate-report-1.json"
  if case.name == "cleanup-after-effect" then
    local effect = matching_effect(recovered, "environment-factory/effects", cleanup_effect)
    t.eq(effect.value.result.status, "cleaned")
    t.eq(recovered.store:load(cleanup_ref), nil)
    local released = recovered:_fixture_effect("fixture-release-status", {
      run_id = context.run_id, artifact_root = context.artifact_root,
    })
    t.eq(released.process_group_absent, true)
    t.eq(released.listeners_closed, true)
    t.eq(released.workspace_absent, true)
  elseif case.name == "publication-after-effect" then
    local effect = matching_effect(recovered, "test-publication/effects", aggregate_effect)
    t.eq(effect.value.result.status, "materialized")
    t.is_true(recovered.store:load(context.artifact_root
      .. "/published/aggregate-report-1-materialization.json") ~= nil)
    t.eq(recovered.store:load(aggregate_receipt_ref), nil)
    local ledger = recovered.publication_runtime.load_ledger(recovered.request.publication.ledger_ref)
    t.eq(ledger.checkpoints["aggregate-report/1"], nil)
  else
    t.eq(#recovered.records:list("testing-runner/replay"), 0)
    t.eq(recovered.store:load(cleanup_ref), nil)
    t.eq(recovered.store:load(aggregate_receipt_ref), nil)
  end
  local barrier_effect
  if case.name == "cleanup-after-effect" then
    barrier_effect = matching_effect(recovered, "environment-factory/effects", cleanup_effect)
  elseif case.name == "publication-after-effect" then
    barrier_effect = matching_effect(recovered, "test-publication/effects", aggregate_effect)
  end
  return recovered, state, barrier_effect and support.copy(barrier_effect) or nil
end

local function assert_terminal(context)
  local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  t.eq(state.version, 18)
  t.eq(state.phase, "terminal")
  t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
  t.eq(#durable.list_indexed_runs(context.project_root, context.durable_root, 10), 1)
  t.eq(process.effect_count(context), 1)
  t.eq(#recovered.records:list("testing-runner/target-effects"), 1)
  t.eq(#recovered.records:list("generic-host/terminal"), 1)
  local terminal = recovered:terminal_record()
  t.eq(terminal.status, "passed")
  local cleanup = recovered.store:load(terminal.cleanup_receipt_ref).value
  t.eq(cleanup.status, "complete")
  t.eq(#cleanup.remaining_resources, 0)
  local publication = recovered.store:load(terminal.aggregate_publication_receipt_ref).value
  t.eq(publication.status, "published")
  t.eq(publication.stage, "aggregate-report")
  return recovered, state
end

local function run_case(case)
  process.with_context({
    cli_only = true, count_effect = true, durable = true, crash_barrier = case.name,
  }, function(context, live_pids)
    local initial = durable.load(context.project_root, context.durable_root, context.run_id)
    local request_binding = support.copy(initial.request)
    local index_binding = support.copy(
      durable.list_indexed_runs(context.project_root, context.durable_root, 10)[1])
    local pid, stdout_path, stderr_path = process.start_supervisor(
      context, "crash-" .. case.name, case.name, live_pids)
    local barrier_path = context.durable_run_root .. "/records/generic-host/barriers/"
      .. case.name .. ".json"
    if not process.wait_for_path(barrier_path, 180) then
      error("generic-host crash matrix: barrier was not reached: " .. case.name
        .. "\nstdout=" .. tostring(process.read_file(stdout_path))
        .. "\nstderr=" .. tostring(process.read_file(stderr_path)))
    end
    local at_barrier, barrier_state, barrier_effect = assert_barrier(context, case)
    local authorization_binding = support.copy(barrier_state.authorization)
    local profile_binding = support.copy(at_barrier.records:list("generic-host/profile-approval")[1].value)
    local preauthorization_binding = support.copy(
      at_barrier.records:list("generic-host/preauthorization")[1].value)
    local barrier_counts = record_counts(at_barrier)
    process.stop_live(pid, live_pids)

    local replacement, replacement_stdout, replacement_stderr = process.start_supervisor(
      context, "replacement-" .. case.name, false, live_pids)
    if not process.wait_for_terminal(context) then
      error("generic-host crash matrix: replacement did not reach terminal: " .. case.name
        .. "\nstdout=" .. tostring(process.read_file(replacement_stdout))
        .. "\nstderr=" .. tostring(process.read_file(replacement_stderr)))
    end
    process.stop_live(replacement, live_pids)
    local recovered, terminal_state = assert_terminal(context)
    t.is_true(support.equal(recovered.request, request_binding))
    t.is_true(support.equal(terminal_state.request, request_binding))
    t.is_true(support.equal(terminal_state.authorization, authorization_binding))
    t.is_true(support.equal(
      durable.list_indexed_runs(context.project_root, context.durable_root, 10)[1], index_binding))
    t.eq(#recovered.records:list("workflow-qa/requests"), 1)
    t.eq(#recovered.records:list("generic-host/profile-approval"), 1)
    t.eq(#recovered.records:list("generic-host/preauthorization"), 1)
    t.is_true(support.equal(
      recovered.records:list("generic-host/profile-approval")[1].value, profile_binding))
    t.is_true(support.equal(
      recovered.records:list("generic-host/preauthorization")[1].value, preauthorization_binding))
    t.eq(#recovered.records:list("testing-runner/replay"), 1)
    t.eq(#recovered.records:list("testing-runner/target-effects"), 1)
    local completed = record_counts(recovered)
    t.is_true(completed.environment_effects >= barrier_counts.environment_effects)
    t.is_true(completed.publications >= barrier_counts.publications)

    local completed_files = durable_file_counts(context)
    if case.name == "cleanup-after-effect" then
      local replayed = matching_effect(recovered, "environment-factory/effects", cleanup_effect)
      t.eq(replayed.key, barrier_effect.key)
      t.is_true(support.equal(replayed.value, barrier_effect.value))
      t.eq(recovered:terminal_record().cleanup_receipt_ref,
        context.artifact_root .. "/cleanup-receipt-complete.json")
      t.eq(completed_files.cleanup_receipts, 1)
    elseif case.name == "publication-after-effect" then
      local replayed = matching_effect(recovered, "test-publication/effects", aggregate_effect)
      t.eq(replayed.key, barrier_effect.key)
      t.is_true(support.equal(replayed.value, barrier_effect.value))
      t.eq(recovered:terminal_record().aggregate_publication_receipt_ref,
        context.artifact_root .. "/publication-receipts/aggregate-report-1.json")
      t.eq(completed_files.aggregate_receipts, 1)
    end
    local noop, noop_stdout, noop_stderr = process.start_supervisor(
      context, "noop-" .. case.name, false, live_pids)
    if not process.wait_for_noop(context, "noop-" .. case.name) then
      error("generic-host crash matrix: second restart was not a no-op: " .. case.name
        .. "\nstdout=" .. tostring(process.read_file(noop_stdout))
        .. "\nstderr=" .. tostring(process.read_file(noop_stderr)))
    end
    process.stop_live(noop, live_pids)
    local after = durable.load(context.project_root, context.durable_root, context.run_id)
    assert_equal_counts(completed, record_counts(after))
    assert_equal_counts(completed_files, durable_file_counts(context))
  end)
end

return {
  test_durable_workflow_qa_real_process_crash_boundary_matrix = function()
    for _, case in ipairs(CASES) do run_case(case) end
  end,
}
