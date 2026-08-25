local graph = require("testkit.graph")
local testing = require("testkit.testing")
local ai_orchestration = require("ai_orchestration")
local core = require("core")
local start_module = require("departments.start_module.main")
local ai_generate = require("departments.ai_generate.main")
local ai_consensus_call = require("departments.ai_consensus_call.main")
local ai_consensus = require("departments.ai_consensus.main")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"
local module_discovery_start_event

local function testing_result(status)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    status = status or "failed",
    artifact_root = ".testing/runs/module-a",
    source_ref = { kind = "external", ref = "module-a" },
    dedup_key = "module-a-run",
    adapter = { name = "fkst-native", mode = "module-no-browser" },
    native_summary = {
      schema = "testing-runner.module-no-browser-summary.v1",
      module = "module-a",
      status = status or "failed",
      mode = "argv",
    },
    exit_code = status == "passed" and 0 or 1,
    stderr_excerpt = status == "passed" and "" or "check failed",
  }
end

local function result_event(status)
  return {
    queue = "testing-runner.testing_result",
    payload = testing_result(status),
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function cdp_result_event(status)
  local classification = status == "passed" and "typed-browser-assertions-passed"
    or status == "failed" and "typed-browser-assertion-failed"
    or "runtime-receipt-invalid"
  local outcome = status == "failed" and "product-defect"
    or status == "blocked" and "harness-tooling-issue"
    or nil
  local summary = {
    schema = "testing-runner.module-cdp-execution-summary.v1",
    module = "module-a",
    status = status,
    execution_status = status,
    classification = classification,
    mode = "bounded-cdp-controller",
    artifact_root = ".testing/runs/module-a-cdp-terminal",
    execution_path = ".testing/runs/module-a-cdp-terminal/cdp-execution.json",
    metadata_path = ".testing/runs/module-a-cdp-terminal/metadata.json",
    action_count = 1,
    planned_action_count = status == "blocked" and 1 or 0,
    blocked_action_count = 0,
    executed_action_count = status == "passed" and 1 or 0,
    failed_action_count = status == "failed" and 1 or 0,
    outcome_classification = outcome,
  }
  return {
    queue = "testing-runner.testing_result",
    payload = {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = status,
      artifact_root = summary.artifact_root,
      source_ref = { kind = "external", ref = "module-a-terminal" },
      trace_id = "trace-module-a-terminal",
      dedup_key = "module-a-terminal-run-" .. status,
      adapter = { name = "fkst-native", mode = status == "blocked" and "module-cdp-execution-blocked" or "module-cdp-execution" },
      native_summary = summary,
    },
    source_ref = { kind = "external", reference = "module-a-terminal" },
  }
end

local function module_start_event()
  return {
    queue = "module_start",
    payload = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      no_browser = true,
      native_argv = { "true" },
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "external", ref = "module-a" },
      dedup_key = "module-a-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function module_ui_loop_start_event()
  return {
    queue = "module_start",
    payload = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
        browser_readiness_ref = ".testing/runs/readiness",
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "read-only",
        gap_ref = ".testing/runs/gap",
        backlog_ref = "backlog-item-1",
      },
      artifact_root = ".testing/runs/module-a-ui",
      source_ref = { kind = "external", ref = "module-a" },
      dedup_key = "module-a-ui-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function module_cdp_execution_start_event()
  local event = module_discovery_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-cdp"
  event.payload.dedup_key = "module-a-cdp-run"
  event.payload.ui_loop.cdp_readiness_ref = "cdp-ready"
  event.payload.cdp_execution = {
    schema = "testing-runner.module-cdp-execution.v1",
    step_budget = 8,
    case_priorities = { "P0", "P1" },
  }
  table.insert(event.payload.preflight_result.sessions, { role = "admin", status = "ready" })
  return event
end

local function module_ai_consensus_start_event()
  local event = module_cdp_execution_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-ai"
  event.payload.dedup_key = "module-a-ai-run"
  event.payload.cdp_execution.ai_generation = {
    schema = "testing-runner.ai-case-generation.request.v1",
    mode = "autonomous-reviewed",
    case_budget = 1,
  }
  return event
end

local function module_missing_cdp_session_start_event()
  local event = module_discovery_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-cdp-missing-session"
  event.payload.dedup_key = "module-a-cdp-missing-session-run"
  event.payload.ui_loop.cdp_readiness_ref = "cdp-ready"
  event.payload.cdp_execution = {
    schema = "testing-runner.module-cdp-execution.v1",
    step_budget = 8,
    case_priorities = { "P0" },
  }
  return event
end

local function module_mutation_execution_start_event()
  local event = module_discovery_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-mutation"
  event.payload.dedup_key = "module-a-mutation-run"
  event.payload.ui_loop.cdp_readiness_ref = "cdp-ready"
  event.payload.ui_loop.mutation_policy = "host-approved"
  event.payload.cdp_execution = {
    schema = "testing-runner.module-cdp-execution.v1",
    step_budget = 8,
    case_priorities = { "P2" },
    mutation_fixtures = {
      {
        case_id = "dashboard:write-flow",
        mutation_kind = "create-test-data",
        fixture_lifecycle_path = ".testing/runs/fixtures/dashboard-lifecycle",
      },
    },
  }
  table.insert(event.payload.preflight_result.sessions, {
    role = "admin",
    status = "ready",
    cdp_url = "http://127.0.0.1:9222",
  })
  return event
end

local function module_fixture_gap_execution_start_event()
  local event = module_mutation_execution_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-fixture-gap"
  event.payload.dedup_key = "module-a-fixture-gap-run"
  event.payload.cdp_execution.mutation_fixtures = nil
  return event
end

module_discovery_start_event = function()
  return {
    queue = "module_start",
    payload = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
        mutation_policy = "read-only",
      },
      module_discovery = {
        schema = "testing-runner.module-discovery.v1",
        observations = {
          {
            id = "dashboard",
            name = "Dashboard",
            entry_url = fixture_base_url .. "/dashboard?user=secret#state",
            visible_label = "Dashboard",
            discovery_source = "navigation",
            confidence = "high",
            evidence_pointer = ".testing/runs/evidence/dashboard",
          },
        },
      },
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
        },
      },
      artifact_root = ".testing/runs/module-a-inventory",
      source_ref = { kind = "external", ref = "module-a" },
      dedup_key = "module-a-inventory-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function prepare_artifact_dir()
  local ok = os.execute("mkdir -p .testing/runs/module-a")
  if ok ~= true and ok ~= 0 then
    error("failed to prepare test artifact directory")
  end
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local body = file:read("*a")
  file:close()
  return body
end

local function consensus_reached_event(proposal, decision)
  return {
    queue = "ai_consensus_result",
    payload = {
      schema = "consensus.consensus_reached.v1",
      proposal_id = proposal.proposal_id,
      decision = decision or "approve",
      body = "raw_prompt token password raw_response must not persist",
      source_ref = proposal.source_ref,
      angle_results = {
        { angle = "teleology", verdict = decision or "approve" },
        { angle = "parsimony", verdict = decision or "approve" },
        { angle = "fidelity", verdict = decision or "approve" },
        { angle = "natural-ownership", verdict = decision or "approve" },
        { angle = "proportional-containment", verdict = decision or "approve" },
      },
    },
    source_ref = proposal.source_ref,
  }
end

local function consensus_converge_event(proposal)
  return {
    queue = "ai_consensus_result",
    payload = {
      schema = "consensus.consensus_converge.v1",
      proposal_id = proposal.proposal_id,
      source_ref = proposal.source_ref,
      narrowed_question = "bounded follow-up",
    },
    source_ref = proposal.source_ref,
  }
end

local function start_ai_generation_proposal()
  local trace = testing.run_fake(start_module, module_ai_consensus_start_event())
  t.eq(#trace.raises, 1)
  t.eq(trace.raises[1].queue, "ai_generation_request")
  local generation_result = {
    stdout = ai_orchestration.json_encode({
      schema = "testing-runner.ai-case-candidates.v1",
      cases = {
        {
          module_id = "dashboard",
          priority = "P1",
          title = "Navigate the dashboard detail surface",
          objective = "Verify bounded navigation exposes the dashboard detail surface.",
          case_kind = "primary-interaction",
          actions = {
            {
              action = "bounded-navigation",
              target = fixture_base_url .. "/dashboard/detail",
              expected = "The dashboard detail surface becomes visible.",
            },
          },
          expected_observable = "The dashboard detail surface remains visible and stable.",
        },
      },
    }),
    stderr = "",
    exit_code = 0,
  }
  local generation_event = {
    queue = "ai_generation_request",
    payload = trace.raises[1].payload,
    source_ref = trace.raises[1].payload.source_ref,
  }
  generation_event["test_" .. "ports"] = {
    generate = function()
      return generation_result
    end,
  }
  local generated = testing.run_fake(ai_generate, generation_event)
  t.eq(#generated.raises, 1)
  t.eq(generated.raises[1].queue, "ai_consensus_request")
  return generated.raises[1].payload
end

return {
  test_run_graph_artifact_summary_flows_to_publication_request = function()
    local trace = graph.require_quiescent(graph.run(result_event("failed"), { max_steps = 8 }))

    graph.require_delivery(trace, {
      queue = "testing-runner.testing_result",
      consumer = "module-testing-pipeline.summarize_result",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.schema, "test-artifacts.summary.v1")
    t.eq(summary.payload.status, "failed")
    t.eq(summary.payload.artifact_root, ".testing/runs/module-a")
    t.eq(summary.payload.metadata_path, ".testing/runs/module-a/metadata.json")
    t.eq(summary.payload.source_ref.ref, "module-a")

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.schema, "test-publication.publication-request.v1")
    t.eq(publication.payload.publication_kind, "testing-summary")
    t.eq(publication.payload.channel, "testing")
    t.eq(publication.payload.severity, "failure")
    t.eq(publication.payload.subject, "Testing failed: module-test-loop")
    t.eq(publication.payload.dedup_key, "module-a-run")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a/metadata.json")
  end,

  test_terminal_cdp_results_flow_to_artifact_summary_and_publication = function()
    local severities = { passed = "success", failed = "failure", blocked = "warning" }
    for _, status in ipairs({ "passed", "failed", "blocked" }) do
      local trace = graph.require_quiescent(graph.run(cdp_result_event(status), { max_steps = 8 }))
      local summary = graph.require_raise(trace, "test-artifacts.artifact_summary").payload
      local publication = graph.require_raise(trace, "test-publication.publication_request").payload
      t.eq(summary.status, status)
      t.eq(summary.native_summary.execution_status, status)
      t.eq(summary.native_summary.failed_action_count, status == "failed" and 1 or 0)
      t.eq(publication.status, status)
      t.eq(publication.severity, severities[status])
    end
  end,

  test_run_graph_no_browser_module_reaches_publication_request = function()
    prepare_artifact_dir()
    t.mock_command("'true'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.require_quiescent(graph.run(module_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "passed")
    t.eq(result.payload.exit_code, 0)
    t.eq(result.payload.adapter.name, "fkst-native")
    t.eq(result.payload.adapter.mode, "module-no-browser")
    t.eq(result.payload.native_summary.mode, "argv")

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "passed")
    t.eq(publication.payload.severity, "success")
    t.eq(publication.payload.subject, "Testing passed: module-test-loop")
    t.eq(publication.payload.dedup_key, "module-a-run/attempt/1")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a")
  end,

  test_run_graph_module_discovery_reaches_inventory_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_discovery_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "degraded")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-inventory-summary.v1")
    t.eq(result.payload.native_summary.discovery_status, "complete")
    t.eq(result.payload.native_summary.inventory_path, ".testing/runs/module-a-inventory/module-inventory.json")
    t.eq(result.payload.native_summary.feature_inventory_path, ".testing/runs/module-a-inventory/feature-inventory.json")
    t.eq(result.payload.native_summary.test_plan_path, ".testing/runs/module-a-inventory/test-plan.json")
    t.eq(result.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-inventory/evidence-bundle.json")
    t.eq(result.payload.native_summary.plan_status, "complete")
    t.eq(result.payload.native_summary.module_count, 1)

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.native_summary.schema, "testing-runner.module-inventory-summary.v1")
    t.eq(summary.payload.native_summary.inventory_path, ".testing/runs/module-a-inventory/module-inventory.json")
    t.eq(summary.payload.native_summary.feature_inventory_path, ".testing/runs/module-a-inventory/feature-inventory.json")
    t.eq(summary.payload.native_summary.test_plan_path, ".testing/runs/module-a-inventory/test-plan.json")
    t.eq(summary.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-inventory/evidence-bundle.json")
    t.eq(summary.payload.native_summary.plan_status, "complete")
    t.eq(summary.payload.native_summary.module_count, 1)

    local bundle = read_file(".testing/runs/module-a-inventory/evidence-bundle.json")
    t.is_true(bundle:find('"discovery_path":".testing/runs/module-a-inventory/evidence/discovery.json"', 1, true) ~= nil)
    local discovery = read_file(".testing/runs/module-a-inventory/evidence/discovery.json")
    t.eq(discovery:find("secret", 1, true), nil)
    t.is_true(discovery:find('"entry_url":"' .. fixture_base_url .. '/dashboard"', 1, true) ~= nil)

    local plan = read_file(".testing/runs/module-a-inventory/test-plan.json")
    t.is_true(plan:find('"schema":"testing-runner.module-test-plan.v1"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P0"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P1"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P2"', 1, true) ~= nil)
    t.is_true(plan:find('"review_status":"executable"', 1, true) ~= nil)
    t.is_true(plan:find('"review_status":"blocked"', 1, true) ~= nil)
    t.is_true(plan:find('"review_status":"not-executed-risk"', 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "degraded")
    t.eq(publication.payload.severity, "warning")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-inventory")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a-inventory/metadata.json")
  end,

  test_run_graph_module_cdp_execution_reaches_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_cdp_execution_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "blocked")
    t.eq(result.payload.adapter.name, "fkst-native")
    t.eq(result.payload.adapter.mode, "module-cdp-execution-blocked")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.payload.native_summary.classification, "missing-cdp-session")
    t.eq(result.payload.native_summary.outcome_classification, "environment-session-issue")
    t.eq(result.payload.native_summary.executed_action_count, 0)
    t.eq(result.payload.native_summary.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(result.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-cdp/evidence-bundle.json")
    t.eq(result.payload.native_summary.action_count, 5)

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.status, "blocked")
    t.eq(summary.payload.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(summary.payload.native_summary.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(summary.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-cdp/evidence-bundle.json")
    t.eq(summary.payload.native_summary.stage_report_path, ".testing/runs/module-a-cdp/stage-report.md")
    t.eq(summary.payload.native_summary.issue_drafts_path, ".testing/runs/module-a-cdp/issue-drafts.json")
    t.eq(summary.payload.native_summary.publication_dry_run, true)
    t.eq(summary.payload.native_summary.action_count, 5)

    local action_trace = read_file(".testing/runs/module-a-cdp/evidence/action-trace.json")
    t.is_true(action_trace:find('"action":"navigate"', 1, true) ~= nil)
    t.eq(action_trace:find("secret", 1, true), nil)

    local execution = read_file(".testing/runs/module-a-cdp/cdp-execution.json")
    t.is_true(execution:find('"action":"navigate"', 1, true) ~= nil)
    t.is_true(execution:find('"url":"' .. fixture_base_url .. '/dashboard"', 1, true) ~= nil)
    t.eq(execution:find("secret", 1, true), nil)

    local report = read_file(".testing/runs/module-a-cdp/stage-report.md")
    t.is_true(report:find("Discovered modules", 1, true) ~= nil)
    t.is_true(report:find("Executed user-facing scenarios", 1, true) ~= nil)
    t.is_true(report:find("Publication handoff: dry-run pointer handoff only", 1, true) ~= nil)
    t.eq(report:find("secret", 1, true), nil)
    local drafts = read_file(".testing/runs/module-a-cdp/issue-drafts.json")
    t.is_true(drafts:find('"publication_dry_run":true', 1, true) ~= nil)
    t.is_true(drafts:find('"external_write":false', 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "blocked")
    t.eq(publication.payload.severity, "warning")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-cdp")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a-cdp/metadata.json")
    t.eq(publication.payload.stage_report_path, ".testing/runs/module-a-cdp/stage-report.md")
    t.eq(publication.payload.issue_drafts_path, ".testing/runs/module-a-cdp/issue-drafts.json")
    t.eq(publication.payload.publication_dry_run, true)
    t.eq(publication.payload.issue_body, nil)
    t.eq(publication.payload.github_comment, nil)
  end,

  test_start_module_authors_cases_before_consensus_review = function()
    local proposal = start_ai_generation_proposal()
    t.eq(proposal.schema, "consensus.proposal.v1")
    t.eq(proposal.verdict_mode, "converge")
    t.eq(proposal.angles, nil)
    t.is_true(proposal.body:find("Review the exact AI-authored", 1, true) ~= nil)
    t.is_true(proposal.body:find(".testing/runs/module-a-ai/ai-context-manifest.json", 1, true) ~= nil)
    t.is_true(proposal.context:find("generated-test-cases.json", 1, true) ~= nil)
    t.is_true(proposal.content_fetch:find("UNTRUSTED-NOTICE.txt", 1, true) ~= nil)
    t.eq(proposal.body:find("secret", 1, true), nil)

    local context = read_file(".testing/runs/module-a-ai/ai-context-manifest.json")
    t.is_true(context:find('"schema":"testing-runner.ai-context-manifest.v1"', 1, true) ~= nil)
    t.is_true(context:find('"entry_url":"' .. fixture_base_url .. '/dashboard"', 1, true) ~= nil)
    t.eq(context:find("secret", 1, true), nil)
    t.eq(context:find("token", 1, true), nil)

    local generated = read_file(".testing/runs/module-a-ai/generated-test-cases.json")
    t.is_true(generated:find('"action":"bounded-navigation"', 1, true) ~= nil)
    local state = read_file(".testing/runs/module-a-ai/ai-orchestration-state.json")
    t.is_true(state:find('"schema":"module-testing-pipeline.ai-orchestration-state.v1"', 1, true) ~= nil)
    t.is_true(state:find('"phase":"generation-proposed"', 1, true) ~= nil)
    t.eq(state:find("secret", 1, true), nil)
    t.eq(state:find("token", 1, true), nil)
    t.eq(state:find("unsafe", 1, true), nil)
  end,

  test_ai_consensus_call_raises_package_owned_result = function()
    local proposal = start_ai_generation_proposal()
    local trace = testing.run_fake(ai_consensus_call, {
      queue = "ai_consensus_request",
      payload = proposal,
      source_ref = proposal.source_ref,
      test_ports = {
        consensus_reach = function(value)
          t.eq(value, proposal)
          return {
            status = "reached",
            schema = "consensus.consensus_reached.v1",
            proposal_id = "must-be-restored-from-request",
            decision = "approve",
            source_ref = value.source_ref,
            angle_results = {},
          }
        end,
      },
    })
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "ai_consensus_result")
    t.eq(trace.raises[1].payload.status, nil)
    t.eq(trace.raises[1].payload.proposal_id, proposal.proposal_id)
    t.eq(trace.raises[1].payload.schema, "consensus.consensus_reached.v1")
  end,

  test_ai_consensus_call_retries_deferred_live_run = function()
    t.eq(ai_consensus_call.spec.retry.max_attempts, 12)
    t.raises(function()
      testing.run_fake(ai_consensus_call, {
        queue = "ai_consensus_request",
        payload = { schema = "consensus.proposal.v1", proposal_id = "deferred-proposal" },
        ["test_" .. "ports"] = { consensus_reach = function() return nil end },
      })
    end)
  end,

  test_ai_consensus_department_raises_review_then_module_loop_request = function()
    local generation_proposal = start_ai_generation_proposal()
    local generation_trace = testing.run_fake(ai_consensus, consensus_reached_event(generation_proposal))
    t.eq(#generation_trace.raises, 1)
    t.eq(generation_trace.raises[1].queue, "ai_consensus_request")
    local review_proposal = generation_trace.raises[1].payload
    t.eq(review_proposal.schema, "consensus.proposal.v1")
    t.eq(review_proposal.verdict_mode, "gate")
    t.eq(review_proposal.source_ref.kind, "testing-ai-review")

    local generated = read_file(".testing/runs/module-a-ai/generated-test-cases.json")
    t.is_true(generated:find('"schema":"testing-runner.generated-test-cases.v1"', 1, true) ~= nil)
    local gate = read_file(".testing/runs/module-a-ai/generated-case-gate.json")
    t.is_true(gate:find('"schema":"testing-runner.generated-case-gate.v1"', 1, true) ~= nil)
    local agent_generation = read_file(".testing/runs/module-a-ai/ai-agent-generation.json")
    t.is_true(agent_generation:find('"generated_case_count":1', 1, true) ~= nil)

    local review_trace = testing.run_fake(ai_consensus, consensus_reached_event(review_proposal))
    t.eq(#review_trace.raises, 1)
    t.eq(review_trace.raises[1].queue, "module-test-loop.module_loop_request")
    local request = review_trace.raises[1].payload
    t.eq(request.schema, "module-test-loop.start.v1")
    t.eq(request.cdp_execution.ai_generation.generated_cases_path, ".testing/runs/module-a-ai/generated-test-cases.json")
    t.eq(request.cdp_execution.ai_generation.ai_agent_generation_path, ".testing/runs/module-a-ai/ai-agent-generation.json")
    t.eq(request.cdp_execution.ai_generation.generated_case_agent_review_path, ".testing/runs/module-a-ai/generated-case-agent-review.json")

    local closure = read_file(".testing/runs/module-a-ai/ai-test-design-loop.json")
    t.is_true(closure:find('"schema":"testing-runner.ai-test-design-loop.v1"', 1, true) ~= nil)
    t.eq(closure:find("raw_prompt", 1, true), nil)
    t.eq(closure:find("token", 1, true), nil)
  end,

  test_ai_consensus_generation_converge_fails_closed_to_local_result = function()
    local generation_proposal = start_ai_generation_proposal()
    local trace = testing.run_fake(ai_consensus, consensus_converge_event(generation_proposal))
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing_result")
    t.eq(trace.raises[1].payload.status, "blocked")
    t.eq(trace.raises[1].payload.adapter.mode, "ai-orchestration-fail-closed")
    local state = read_file(".testing/runs/module-a-ai/ai-orchestration-state.json")
    t.is_true(state:find('"phase":"blocked"', 1, true) ~= nil)
  end,

  test_ai_consensus_review_reject_fails_closed_without_module_loop_request = function()
    local generation_proposal = start_ai_generation_proposal()
    local generation_trace = testing.run_fake(ai_consensus, consensus_reached_event(generation_proposal))
    local review_proposal = generation_trace.raises[1].payload
    local trace = testing.run_fake(ai_consensus, consensus_reached_event(review_proposal, "reject"))
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing_result")
    t.eq(trace.raises[1].payload.status, "blocked")
  end,

  test_start_and_generation_departments_raise_local_blocked_results = function()
    local original_start = core.start_ai_orchestration
    core.start_ai_orchestration = function()
      return { kind = "blocked-result", result = testing_result("blocked") }
    end
    local start_trace = testing.run_fake(start_module, module_ai_consensus_start_event())
    core.start_ai_orchestration = original_start
    t.eq(start_trace.raises[1].queue, "testing_result")
    t.eq(start_trace.raises[1].payload.status, "blocked")

    local original_generate = core.generate_ai_cases
    core.generate_ai_cases = function()
      return { kind = "blocked-result", result = testing_result("blocked") }
    end
    local generation_trace = testing.run_fake(ai_generate, {
      queue = "ai_generation_request",
      payload = { schema = "module-testing-pipeline.ai-generation-request.v1" },
    })
    core.generate_ai_cases = original_generate
    t.eq(generation_trace.raises[1].queue, "testing_result")
    t.eq(generation_trace.raises[1].payload.status, "blocked")
  end,

  test_run_graph_missing_cdp_session_classifies_environment_issue = function()
    local trace = graph.require_quiescent(graph.run(module_missing_cdp_session_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "blocked")
    t.eq(result.payload.native_summary.classification, "missing-cdp-session")
    t.eq(result.payload.native_summary.outcome_classification, "environment-session-issue")
    t.eq(result.payload.native_summary.gap_backlog_path, ".testing/runs/module-a-cdp-missing-session/gap-backlog.json")

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.status, "blocked")
    t.eq(summary.payload.native_summary.outcome_classification, "environment-session-issue")
    t.eq(summary.payload.native_summary.gap_backlog_path, ".testing/runs/module-a-cdp-missing-session/gap-backlog.json")

    local backlog = read_file(".testing/runs/module-a-cdp-missing-session/gap-backlog.json")
    t.is_true(backlog:find('"outcome_classification":"environment-session-issue"', 1, true) ~= nil)
    t.is_true(backlog:find("Restore local server/readiness/login/CDP session inputs", 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "blocked")
    t.eq(publication.payload.severity, "warning")
  end,

  test_run_graph_safe_mutation_plan_reaches_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_mutation_execution_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "degraded")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.payload.native_summary.classification, "mutation-execution-deferred")
    t.eq(result.payload.native_summary.action_count, 1)
    t.eq(result.payload.native_summary.planned_action_count, 1)
    t.eq(result.payload.native_summary.blocked_action_count, 0)
    t.eq(result.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-mutation/evidence-bundle.json")
    t.eq(result.payload.native_summary.fixture_lifecycle_path, nil)

    local execution = read_file(".testing/runs/module-a-mutation/cdp-execution.json")
    t.is_true(execution:find('"action":"safe-mutation-fixture"', 1, true) ~= nil)
    t.is_true(execution:find('"fixture_lifecycle_path":".testing/runs/fixtures/dashboard-lifecycle"', 1, true) ~= nil)

    local metadata = read_file(".testing/runs/module-a-mutation/metadata.json")
    t.eq(metadata:find("fixture_lifecycle_path", 1, true), nil)

    local action_trace = read_file(".testing/runs/module-a-mutation/evidence/action-trace.json")
    t.is_true(action_trace:find('"fixture_lifecycle_path":".testing/runs/fixtures/dashboard-lifecycle"', 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "degraded")
    t.eq(publication.payload.severity, "warning")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-mutation")
  end,

  test_run_graph_fixture_gap_classifies_data_issue = function()
    local trace = graph.require_quiescent(graph.run(module_fixture_gap_execution_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "degraded")
    t.eq(result.payload.native_summary.classification, "no-executable-safe-cases")
    t.eq(result.payload.native_summary.outcome_classification, "data-fixture-gap")
    t.eq(result.payload.native_summary.gap_backlog_path, ".testing/runs/module-a-fixture-gap/gap-backlog.json")

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.status, "degraded")
    t.eq(summary.payload.native_summary.outcome_classification, "data-fixture-gap")
    t.eq(summary.payload.native_summary.gap_backlog_path, ".testing/runs/module-a-fixture-gap/gap-backlog.json")

    local backlog = read_file(".testing/runs/module-a-fixture-gap/gap-backlog.json")
    t.is_true(backlog:find('"outcome_classification":"data-fixture-gap"', 1, true) ~= nil)
    t.is_true(backlog:find("cleanup or rollback", 1, true) ~= nil)
    local metadata = read_file(".testing/runs/module-a-fixture-gap/metadata.json")
    t.eq(metadata:find("fixture_lifecycle_path", 1, true), nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "degraded")
    t.eq(publication.payload.severity, "warning")
  end,

  test_run_graph_module_ui_loop_reaches_degraded_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_ui_loop_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "module-testing-pipeline.module_start",
      consumer = "module-testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "degraded")
    t.eq(result.payload.adapter.name, "fkst-native")
    t.eq(result.payload.adapter.mode, "module-ui-loop-contract")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-ui-loop-summary.v1")
    t.eq(result.payload.native_summary.classification, "browser-exploration-deferred")
    t.eq(result.payload.native_summary.outcome_classification, "harness-tooling-issue")
    t.eq(result.payload.native_summary.artifact_root, ".testing/runs/module-a-ui")
    t.eq(result.payload.native_summary.metadata_path, ".testing/runs/module-a-ui/metadata.json")
    t.eq(result.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-ui/evidence-bundle.json")
    t.eq(result.payload.native_summary.gap_backlog_path, ".testing/runs/module-a-ui/gap-backlog.json")
    t.eq(result.payload.native_summary.gap_ref, ".testing/runs/gap")
    t.eq(result.payload.native_summary.backlog_ref, "backlog-item-1")

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.status, "degraded")
    t.eq(summary.payload.native_summary.schema, "testing-runner.module-ui-loop-summary.v1")
    t.eq(summary.payload.native_summary.outcome_classification, "harness-tooling-issue")
    t.eq(summary.payload.native_summary.metadata_path, ".testing/runs/module-a-ui/metadata.json")
    t.eq(summary.payload.native_summary.evidence_bundle_path, ".testing/runs/module-a-ui/evidence-bundle.json")
    t.eq(summary.payload.native_summary.gap_backlog_path, ".testing/runs/module-a-ui/gap-backlog.json")
    t.eq(summary.payload.artifact_root, ".testing/runs/module-a-ui")

    local bundle = read_file(".testing/runs/module-a-ui/evidence-bundle.json")
    t.is_true(bundle:find('"failures_path":".testing/runs/module-a-ui/evidence/failures.json"', 1, true) ~= nil)
    t.is_true(bundle:find('"gap_backlog_path":".testing/runs/module-a-ui/gap-backlog.json"', 1, true) ~= nil)
    local failures = read_file(".testing/runs/module-a-ui/evidence/failures.json")
    t.is_true(failures:find('"classification":"browser-exploration-deferred"', 1, true) ~= nil)
    local backlog = read_file(".testing/runs/module-a-ui/gap-backlog.json")
    t.is_true(backlog:find('"outcome_classification":"harness-tooling-issue"', 1, true) ~= nil)
    t.is_true(backlog:find("browser exploration support", 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "degraded")
    t.eq(publication.payload.severity, "warning")
    t.eq(publication.payload.subject, "Testing degraded: module-test-loop")
    t.eq(publication.payload.dedup_key, "module-a-ui-run/attempt/1")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-ui")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a-ui/metadata.json")
  end,
}
