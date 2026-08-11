local durable = require("host_durable_workflow_qa")
local process = require("test_support.durable_workflow_qa_process")
local support = require("host_canonical_workflow_qa_support")
local t = fkst.test

local CASE_IDS = {
  "inventory-initial-state", "inventory-reserve-three", "inventory-state-after-reserve",
  "inventory-over-reserve-rejected", "inventory-state-after-rejection",
}
local INITIAL = "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":0,\"available\":5}\n"
local RESERVED = "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":3,\"available\":2}\n"
local REJECTED = "{\"error\":\"insufficient-available\",\"sku\":\"SKU-001\",\"requested\":3,\"available\":2}\n"

local function adapter_log_root(context, label)
  return context.host_root .. "/framework-runtime-" .. label .. "/logs/framework-child"
end

local function adapter_marker_counts(context, label)
  local root = adapter_log_root(context, label)
  return {
    intake = process.count_child_logs(root, "local-qa-host-adapter.intake-",
      "local-qa-host dept=intake tag=ROUTED run_id=" .. context.run_id),
    execution_grant = process.count_child_logs(root, "local-qa-host-adapter.execution_grant-",
      "local-qa-host dept=execution_grant tag=GRANTED"),
    terminal = process.count_child_logs(root, "local-qa-host-adapter.terminal-",
      "local-qa-host dept=terminal tag=RECORDED run_id=" .. context.run_id),
  }
end

local function add_marker_counts(total, counts)
  for name, value in pairs(counts) do total[name] = total[name] + value end
end

local function artifact(context, path)
  local stored = context.store:load(path)
  t.is_true(type(stored) == "table")
  t.is_true(type(stored.digest) == "string" and stored.digest:match("^[0-9a-f]+$") ~= nil)
  t.eq(#stored.digest, 64)
  t.eq(context.store:digest(path), stored.digest)
  return stored.value
end

local function case_id(effect)
  local binding = effect.binding
  return binding.case_id or binding.action_envelope.case.case_id
end

local function sorted_effects(context)
  local effects = context.records:list("testing-runner/target-effects")
  table.sort(effects, function(left, right) return left.value.sequence < right.value.sequence end)
  return effects
end

local function counts(context)
  return {
    profile = #context.records:list("generic-host/profile-approval"),
    preauthorization = #context.records:list("generic-host/preauthorization"),
    replay = #context.records:list("testing-runner/replay"),
    authorization = #context.records:list("testing-runner/cli-effect-authorizations"),
    consumption = #context.records:list("testing-runner/cli-effect-consumptions"),
    effects = #context.records:list("testing-runner/target-effects"),
    publication = #context.records:list("test-publication/effects"),
    terminal = #context.records:list("generic-host/terminal"),
  }
end

local function assert_same_counts(before, after)
  for name, value in pairs(before) do t.eq(after[name], value) end
end

return {
  test_stateful_inventory_reservation_survives_whole_plan_recovery = function()
    process.with_context({
      scenario = "downstream-inventory", durable = true, prepare_execution_grant_pending = false,
      publication_channel = "filesystem-dry-run-v1", arm_completed_replay_failpoint = true,
    }, function(context, live_pids)
      t.eq(#context.commit_sha, 40)
      t.is_true(context.commit_sha:match("^[0-9a-f]+$") ~= nil)
      t.eq(context.request.repository.commit_sha, context.commit_sha)
      t.eq(context.profile.mutation_policy.mode, "fixture-scoped")
      t.eq(context.profile.mutation_policy.allowed_operations[1], "update")
      for _, name in ipairs({
        "load_artifact", "write_artifact", "artifact_digest", "claim_preauthorization",
        "grant_values", "record_terminal",
      }) do
        t.eq(type(context.generic_host_runtime[name]), "function")
      end

      local first_pid, first_stdout, first_stderr = process.start_supervisor(
        context, "inventory-first", true, live_pids)
      local barrier_path = context.durable_run_root .. "/records/generic-host/barriers/post-replay-complete.json"
      if not process.wait_for_path(barrier_path, 180) then
        error("inventory acceptance did not reach replay barrier\nstdout=" .. tostring(process.read_file(first_stdout))
          .. "\nstderr=" .. tostring(process.read_file(first_stderr)))
      end
      local at_barrier = durable.load(context.project_root, context.durable_root, context.run_id)
      local replay = at_barrier.records:list("testing-runner/replay")
      t.eq(#replay, 1)
      t.eq(replay[1].value.status, "completed")
      local barrier = at_barrier.records:read("generic-host/barriers/post-replay-complete")
      t.eq(barrier.result_ref, replay[1].value.result_ref)
      t.eq(barrier.result_sha256, replay[1].value.result_sha256)
      local execution = artifact(at_barrier, barrier.result_ref)
      t.eq(barrier.case_results_ref, execution.case_results_path)
      t.eq(barrier.case_results_sha256, at_barrier.store:digest(barrier.case_results_ref))
      local barrier_results = artifact(at_barrier, barrier.case_results_ref)
      t.eq(#barrier_results.cases, 5)
      local resolved = support.require_exec({ "git", "rev-parse", "HEAD" }, at_barrier.workspace_root)
        :match("([0-9a-f]+)")
      t.eq(resolved, context.commit_sha)
      t.is_true(at_barrier.workspace_root ~= at_barrier.fixture_source_root)
      t.eq(support.read_file(at_barrier.workspace_root .. "/source-only-uncommitted.txt"), nil)
      t.eq(support.read_file(at_barrier.workspace_root .. "/state/inventory.json"), RESERVED)
      local effects = sorted_effects(at_barrier)
      t.eq(#effects, 5)
      for index, expected in ipairs(CASE_IDS) do
        t.eq(effects[index].value.sequence, index)
        t.eq(case_id(effects[index].value), expected)
      end
      t.eq(effects[1].value.result.status, 200)
      t.eq(effects[1].value.result.headers["content-type"], "application/json")
      t.eq(effects[1].value.result.body, INITIAL)
      t.eq(effects[2].value.result.exit_code, 0)
      t.eq(effects[2].value.result.stdout, RESERVED)
      t.eq(effects[2].value.result.stderr, "")
      t.eq(effects[3].value.result.body, RESERVED)
      t.eq(effects[4].value.result.exit_code, 4)
      t.eq(effects[4].value.result.stdout, "")
      t.eq(effects[4].value.result.stderr, REJECTED)
      t.eq(effects[5].value.result.body, RESERVED)
      t.eq(#at_barrier.records:list("testing-runner/cli-effect-authorizations"), 2)
      t.eq(#at_barrier.records:list("testing-runner/cli-effect-consumptions"), 2)
      for _, expected in ipairs({ "inventory-reserve-three", "inventory-over-reserve-rejected" }) do
        local consumption = artifact(at_barrier, at_barrier.request.structured_execution.artifact_root
          .. "/authorization/" .. expected .. "-consumption.json")
        t.eq(consumption.schema, "generic-host.cli-effect-consumption.v1")
        t.eq(consumption.case_id, expected)
      end
      t.eq(at_barrier:terminal_record(), nil)
      local ownership = at_barrier:_fixture_effect("fixture-resource-status", {
        run_id = context.run_id, artifact_root = context.artifact_root,
      })
      t.eq(ownership.owned, true)
      t.eq(ownership.pgid, ownership.pid)
      t.eq(ownership.workspace_path, context.workspace_root)
      process.stop_live(first_pid, live_pids)
      local surviving = at_barrier:_fixture_effect("fixture-resource-status", {
        run_id = context.run_id, artifact_root = context.artifact_root,
      })
      t.eq(surviving.owned, true)
      t.eq(surviving.pgid, ownership.pgid)
      t.eq(surviving.ownership_token, ownership.ownership_token)
      local adapter_calls = { intake = 0, execution_grant = 0, terminal = 0 }
      add_marker_counts(adapter_calls, adapter_marker_counts(context, "inventory-first"))

      local second_pid, second_stdout, second_stderr = process.start_supervisor(
        context, "inventory-second", false, live_pids)
      if not process.wait_for_terminal(context) then
        error("inventory replacement did not reach terminal\nstdout=" .. tostring(process.read_file(second_stdout))
          .. "\nstderr=" .. tostring(process.read_file(second_stderr)))
      end
      process.stop_live(second_pid, live_pids)
      add_marker_counts(adapter_calls, adapter_marker_counts(context, "inventory-second"))
      local recovered = durable.load(context.project_root, context.durable_root, context.run_id)
      t.eq(recovered.records:read("generic-host/recovery/execution").replayed, true)
      local catalog = artifact(recovered, recovered.request.structured_execution.case_catalog_ref)
      local plan = artifact(recovered, recovered.request.structured_execution.structured_plan_ref)
      local results = artifact(recovered, recovered.request.structured_execution.artifact_root .. "/case-results.json")
      t.eq(#catalog.cases, 5)
      t.eq(#plan.cases, 5)
      t.eq(#results.cases, 5)
      for index, expected in ipairs(CASE_IDS) do
        t.eq(catalog.cases[index].case_id, expected)
        t.eq(catalog.cases[index].design_case_id, expected)
        t.eq(plan.cases[index].case_id, expected)
        t.eq(results.cases[index].case_id, expected)
        t.eq(results.cases[index].status, "passed")
        artifact(recovered, results.cases[index].evidence_ref)
      end
      t.eq(catalog.cases[2].argv[1], "node")
      t.eq(catalog.cases[2].argv[2], "cli.js")
      t.eq(catalog.cases[2].argv[3], "reserve")
      t.eq(catalog.cases[2].argv[4], "SKU-001")
      t.eq(catalog.cases[2].argv[5], "3")
      t.is_true(support.equal(catalog.cases[2].argv, catalog.cases[4].argv))
      local preauthorization = artifact(recovered, recovered.request.structured_execution.preauthorization_ref)
      t.eq(#preauthorization.capabilities.cli, 1)
      t.is_true(support.equal(preauthorization.capabilities.cli[1].argv_prefix, catalog.cases[2].argv))
      t.eq(#preauthorization.capabilities.http, 1)
      t.eq(preauthorization.capabilities.http[1].origin, recovered.origin)
      t.eq(preauthorization.capabilities.http[1].methods[1], "GET")
      t.eq(preauthorization.capabilities.http[1].path_prefixes[1], "/inventory/")

      local terminal = recovered:terminal_record()
      t.eq(terminal.schema, "workflow-qa.terminal-request.v2")
      t.eq(terminal.status, "passed")
      for name, expected in pairs({
        planned = 5, executed = 5, passed = 5, failed = 0, skipped = 0, error = 0, blocked = 0,
      }) do t.eq(terminal.counts[name], expected) end
      local publication = artifact(recovered, terminal.aggregate_publication_receipt_ref)
      t.eq(publication.status, "published")
      t.eq(publication.channel, "filesystem-dry-run-v1")
      t.eq(publication.remote_url, nil)
      local aggregate = artifact(recovered, recovered.request.publication.aggregate_report_ref)
      t.eq(aggregate.status, "passed")
      t.eq(aggregate.counts.passed, 5)
      local cleanup = artifact(recovered, terminal.cleanup_receipt_ref)
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      local report_path = recovered.artifact_root .. "/acceptance-report.md"
      local report = artifact(recovered, report_path)
      t.is_true(type(report) == "string")
      local previous = 0
      for _, expected in ipairs(CASE_IDS) do
        local position = assert(report:find(expected, previous + 1, true))
        t.is_true(position > previous)
        previous = position
      end
      t.eq(report:match("([^\n]+)\n$"), "Verdict: downstream business acceptance passed")
      local released = recovered:_fixture_effect("fixture-release-status", {
        run_id = context.run_id, artifact_root = context.artifact_root,
      })
      t.eq(released.process_group_absent, true)
      t.eq(released.listeners_closed, true)
      t.eq(released.workspace_absent, true)
      t.eq(support.read_file(context.workspace_root .. "/state/inventory.json"), nil)

      local before = counts(recovered)
      local noop_pid, noop_stdout, noop_stderr = process.start_supervisor(
        context, "inventory-noop", false, live_pids)
      if not process.wait_for_noop(context, "inventory-noop") then
        error("inventory terminal replay was not a no-op\nstdout=" .. tostring(process.read_file(noop_stdout))
          .. "\nstderr=" .. tostring(process.read_file(noop_stderr)))
      end
      process.stop_live(noop_pid, live_pids)
      add_marker_counts(adapter_calls, adapter_marker_counts(context, "inventory-noop"))
      t.eq(#durable.load(context.project_root, context.durable_root, context.run_id).records:list(
        "generic-host/local-qa-intake"), 1)
      t.eq(adapter_calls.intake, 1)
      t.eq(adapter_calls.execution_grant, 1)
      t.eq(adapter_calls.terminal, 1)
      assert_same_counts(before, counts(durable.load(context.project_root, context.durable_root, context.run_id)))
      t.eq(before.profile, 1)
      t.eq(before.preauthorization, 1)
      t.eq(before.replay, 1)
      t.eq(before.authorization, 2)
      t.eq(before.consumption, 2)
      t.eq(before.effects, 5)
      t.eq(before.publication, 1)
      t.eq(before.terminal, 1)
    end)
  end,
}
