local durable = require("host_durable_workflow_qa")
local process = require("test_support.durable_workflow_qa_process")
local support = require("host_canonical_workflow_qa")
local supervisor_support = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local CASES = {
  { name = "intake-checkpoint", phase = "checkpoint-pending", stage = "intake",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "environment-pending", phase = "environment-pending",
    queue = "environment-factory.environment_start", marker = "environment-factory dept=start " },
  { name = "environment-ready-checkpoint", phase = "checkpoint-pending", stage = "environment-ready",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "analysis-pending", phase = "analysis-pending",
    queue = "testing-design.analysis_request", marker = "testing-design dept=start " },
  { name = "design-round-checkpoint", phase = "checkpoint-pending", stage = "design-round",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "browser-readiness-pending", phase = "browser-readiness-pending",
    queue = "browser-readiness.browser_readiness_check", marker = "browser-readiness dept=check_readiness " },
  { name = "browser-readiness-checkpoint", phase = "checkpoint-pending", stage = "browser-readiness",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "module-pending", phase = "module-pending",
    queue = "module-testing-pipeline.module_start", marker = "module-testing-pipeline dept=start_module " },
  { name = "design-closure-checkpoint", phase = "checkpoint-pending", stage = "design-closure",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "structured-plan-pending", phase = "structured-plan-pending",
    queue = "testing-runner.structured_plan_request", marker = "testing-runner dept=compile_structured_plan " },
  { name = "execution-grant-pending", phase = "execution-grant-pending",
    queue = "workflow_qa_execution_grant_request", marker = "generic-host dept=workflow_qa_grant " },
  { name = "structured-execution-pending", phase = "structured-execution-pending",
    queue = "testing-runner.structured_execution_request", marker = "testing-runner dept=run_structured_execution " },
  { name = "artifact-summary-pending", phase = "artifact-summary-pending",
    queue = "test-artifacts.testing_result", marker = "test-artifacts dept=summarize " },
  { name = "execution-batch-checkpoint", phase = "checkpoint-pending", stage = "execution-batch",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "cleanup-pending", phase = "cleanup-pending",
    queue = "environment-factory.environment_finalize", marker = "environment-factory dept=finalize " },
  { name = "cleanup-checkpoint", phase = "checkpoint-pending", stage = "cleanup",
    queue = "test-publication.qa_checkpoint_request", marker = "test-publication dept=record_qa_checkpoint " },
  { name = "publication-pending", phase = "publication-pending",
    queue = "test-publication.qa_finalize_request", marker = "test-publication dept=finalize_qa_run " },
  { name = "terminal-without-host-record", phase = "terminal",
    queue = "workflow_qa_terminal_request", marker = "generic-host dept=workflow_qa_terminal " },
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

local function assert_counts_equal(left, right)
  for key, value in pairs(left) do t.eq(right[key], value) end
end

local function durable_bindings(context)
  local bindings = {}
  for _, prefix in ipairs({
    "environment-factory/effects",
    "test-publication/effects",
    "generic-host/profile-approval",
    "generic-host/preauthorization",
    "testing-runner/replay",
    "testing-runner/target-effects",
    "generic-host/terminal",
  }) do
    for _, entry in ipairs(context.records:list(prefix)) do bindings[entry.key] = support.copy(entry.value) end
  end
  return bindings
end

local function assert_bindings_preserved(context, expected)
  for key, value in pairs(expected) do t.is_true(support.equal(context.records:read(key), value)) end
end

local function assert_child_marker(root, prefix, fragment, case_name)
  if not process.wait_for_child_text(root, prefix, fragment, 5) then
    error("generic-host startup redrive test: " .. case_name
      .. " missing child route marker " .. fragment)
  end
end

local function assert_prepared(context, case)
  local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  t.eq(state.phase, case.phase)
  t.eq(type(state.active_checkpoint) == "table" and state.active_checkpoint.stage or nil, case.stage)
  t.eq(#state.pending_actions, 1)
  t.eq(state.pending_actions[1].queue, case.queue)
  t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 1)
  t.eq(#durable.list_indexed_runs(context.project_root, context.durable_root, 10), 1)
  t.eq(#recovered.records:list("workflow-qa/requests"), 1)
  t.eq(recovered:terminal_record(), nil)
  return recovered, state
end

local function assert_terminal(context)
  local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
  local state = recovered.workflow_runtime.load_state(recovered.request.state_ref)
  t.eq(state.phase, "terminal")
  t.eq(#durable.list_pending(context.project_root, context.durable_root, 10), 0)
  t.eq(#durable.list_indexed_runs(context.project_root, context.durable_root, 10), 1)
  t.eq(#recovered.records:list("workflow-qa/requests"), 1)
  t.eq(#recovered.records:list("generic-host/profile-approval"), 1)
  t.eq(#recovered.records:list("generic-host/preauthorization"), 1)
  t.eq(#recovered.records:list("testing-runner/replay"), 1)
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
    cli_only = true,
    count_effect = true,
    durable = true,
    prepare_execution_grant_pending = false,
  }, function(context, live_pids)
    local preparation = durable.load(context.project_root, context.durable_root, context.run_id)
    supervisor_support.prepare_phase(preparation, context.project_root, case.name)
    local prepared, prepared_state = assert_prepared(context, case)
    local request_binding = support.copy(prepared.request)
    local authorization_binding = support.copy(prepared_state.authorization)
    local index_binding = durable.list_indexed_runs(context.project_root, context.durable_root, 10)[1]
    local before = record_counts(prepared)
    local persisted_bindings = durable_bindings(prepared)

    local pid, stdout_path, stderr_path = process.start_supervisor(
      context, "startup-" .. case.name, false, live_pids)
    if not process.wait_for_terminal(context) then
      error("generic-host startup redrive test: " .. case.name .. " did not reach terminal\nstdout="
        .. tostring(process.read_file(stdout_path)) .. "\nstderr=" .. tostring(process.read_file(stderr_path)))
    end
    process.stop_live(pid, live_pids)
    local child_root = context.host_root .. "/framework-runtime-startup-" .. case.name
      .. "/logs/framework-child"
    assert_child_marker(child_root, "generic-host.workflow_qa_supervisor-",
      "generic-host dept=workflow_qa_supervisor tag=REDRIVE_RUN run_id=" .. context.run_id, case.name)
    assert_child_marker(child_root, "workflow-qa.seam-",
      "workflow-qa dept=seam tag=REDRIVE actions=1 queue=" .. case.queue, case.name)
    assert_child_marker(child_root, "", case.marker, case.name)
    assert_child_marker(child_root, "generic-host.workflow_qa_terminal-",
      "generic-host dept=workflow_qa_terminal tag=RECORDED run_id=" .. context.run_id, case.name)

    local recovered, terminal_state = assert_terminal(context)
    t.is_true(support.equal(recovered.request, request_binding))
    t.is_true(support.equal(terminal_state.request, request_binding))
    t.is_true(support.equal(terminal_state.authorization, authorization_binding))
    t.is_true(support.equal(
      durable.list_indexed_runs(context.project_root, context.durable_root, 10)[1], index_binding))
    assert_bindings_preserved(recovered, persisted_bindings)
    local completed = record_counts(recovered)
    t.is_true(completed.environment_effects >= before.environment_effects)
    t.is_true(completed.publications >= before.publications)

    local noop_pid, noop_stdout, noop_stderr = process.start_supervisor(
      context, "noop-" .. case.name, false, live_pids)
    if not process.wait_for_noop(context, "noop-" .. case.name) then
      error("generic-host startup redrive test: " .. case.name .. " second start was not a no-op\nstdout="
        .. tostring(process.read_file(noop_stdout)) .. "\nstderr=" .. tostring(process.read_file(noop_stderr)))
    end
    process.stop_live(noop_pid, live_pids)
    assert_counts_equal(completed,
      record_counts(durable.load(context.project_root, context.durable_root, context.run_id)))
  end)
end

return {
  test_durable_workflow_qa_startup_redrives_every_persisted_structured_success_phase = function()
    for _, case in ipairs(CASES) do run_case(case) end
  end,
}
