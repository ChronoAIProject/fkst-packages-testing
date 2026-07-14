local graph = require("testkit.graph")
local testing = require("testkit.testing")
local ai_orchestration = require("ai_orchestration")
local start_module = require("departments.start_module.main")
local ai_generate = require("departments.ai_generate.main")
local ai_consensus = require("departments.ai_consensus.main")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function module_ai_consensus_start_event()
  return {
    queue = "module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
        browser_readiness_ref = ".testing/runs/readiness/module-a",
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "read-only",
      },
      module_discovery = {
        schema = "testing-runner.module-discovery.v1",
        observations = {
          {
            id = "dashboard",
            name = "Dashboard",
            entry_url = fixture_base_url .. "/dashboard?token=secret#state",
            visible_label = "Dashboard",
            discovery_source = "navigation",
            confidence = "high",
            evidence_pointer = ".testing/runs/evidence/dashboard",
          },
        },
      },
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        step_budget = 8,
        case_priorities = { "P0", "P1" },
        ai_generation = {
          schema = "testing-runner.ai-case-generation.request.v1",
          mode = "autonomous-reviewed",
          case_budget = 1,
        },
      },
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
          { role = "admin", status = "ready" },
        },
      },
      artifact_root = ".testing/runs/module-a-ai-smoke",
      source_ref = { kind = "external", ref = "module-a" },
      trace_id = "trace-module-a-ai-smoke",
      dedup_key = "module-a-ai-smoke-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local body = file:read("*a")
  file:close()
  return body
end

local function consensus_reached_event(proposal)
  return {
    queue = "consensus.consensus_reached",
    payload = {
      schema = "consensus.consensus_reached.v1",
      proposal_id = proposal.proposal_id,
      decision = "approve",
      body = "raw_prompt token password raw_response must not persist",
      source_ref = proposal.source_ref,
      angle_results = {
        { angle = "teleology", verdict = "approve", exit_code = 0 },
        { angle = "parsimony", verdict = "approve", exit_code = 0 },
        { angle = "fidelity", verdict = "approve", exit_code = 0 },
        { angle = "natural-ownership", verdict = "approve", exit_code = 0 },
        { angle = "proportional-containment", verdict = "approve", exit_code = 0 },
      },
    },
    source_ref = proposal.source_ref,
  }
end

local function start_ai_generation_proposal()
  local trace = testing.run_fake(start_module, module_ai_consensus_start_event())
  t.eq(#trace.raises, 1)
  t.eq(trace.raises[1].queue, "ai_generation_request")
  t.mock_command("codex exec", {
    stdout = ai_orchestration.json_encode({
      schema = "testing-runner.ai-case-candidates.v1",
      cases = {
        {
          module_id = "dashboard",
          priority = "P1",
          title = "Open the reviewed dashboard surface",
          objective = "Verify the reviewed AI case opens the visible dashboard surface.",
          case_kind = "read-only-interaction",
          actions = {
            {
              action = "open-visible-surface",
              target = "Dashboard",
              expected = "Dashboard details remain visible.",
            },
          },
          expected_observable = "Dashboard remains visible and same-origin.",
        },
      },
    }),
    stderr = "",
    exit_code = 0,
  })
  local generated = testing.run_fake(ai_generate, {
    queue = "ai_generation_request",
    payload = trace.raises[1].payload,
    source_ref = trace.raises[1].payload.source_ref,
  })
  t.eq(#generated.raises, 1)
  t.eq(generated.raises[1].queue, "consensus.proposal")
  return generated.raises[1].payload
end

local function terminal_result_event(request)
  local root = request.artifact_root
  return {
    queue = "testing-runner.testing_result",
    payload = {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "blocked",
      artifact_root = root,
      source_ref = request.source_ref,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
      adapter = { name = "fkst-native", mode = "module-cdp-execution-blocked" },
      native_summary = {
        schema = "testing-runner.module-cdp-execution-summary.v1",
        module = request.module,
        status = "blocked",
        execution_status = "blocked",
        classification = "missing-cdp-session",
        mode = "bounded-cdp-controller",
        artifact_root = root,
        execution_path = root .. "/cdp-execution.json",
        metadata_path = root .. "/metadata.json",
        stage_report_path = root .. "/stage-report.md",
        issue_drafts_path = root .. "/issue-drafts.json",
        publication_dry_run = true,
        action_count = 1,
        planned_action_count = 1,
        blocked_action_count = 0,
        executed_action_count = 0,
        failed_action_count = 0,
        generated_cases_path = request.cdp_execution.ai_generation.generated_cases_path,
        generated_case_agent_review_path = request.cdp_execution.ai_generation.generated_case_agent_review_path,
      },
    },
    source_ref = {
      kind = (request.source_ref or {}).kind or "external",
      reference = (request.source_ref or {}).ref or request.module,
    },
  }
end

return {
  test_ai_author_review_pipeline_smoke_produces_reviewed_pointer_request_and_publication_handoff = function()
    local generation_proposal = start_ai_generation_proposal()
    t.eq(generation_proposal.schema, "consensus.proposal.v1")
    t.eq(generation_proposal.verdict_mode, "converge")
    t.is_true(generation_proposal.body:find("Review the exact AI-authored", 1, true) ~= nil)

    local generation_trace = testing.run_fake(ai_consensus, consensus_reached_event(generation_proposal))
    t.eq(#generation_trace.raises, 1)
    t.eq(generation_trace.raises[1].queue, "consensus.proposal")
    local review_proposal = generation_trace.raises[1].payload
    t.eq(review_proposal.verdict_mode, "gate")
    t.eq(review_proposal.source_ref.kind, "testing-ai-review")

    local review_trace = testing.run_fake(ai_consensus, consensus_reached_event(review_proposal))
    t.eq(#review_trace.raises, 1)
    t.eq(review_trace.raises[1].queue, "module-test-loop.module_loop_request")
    local request = review_trace.raises[1].payload
    t.eq(request.schema, "module-test-loop.start.v1")
    t.eq(request.cdp_execution.ai_generation.generated_cases_path, ".testing/runs/module-a-ai-smoke/generated-test-cases.json")
    t.eq(request.cdp_execution.ai_generation.generated_case_agent_review_path, ".testing/runs/module-a-ai-smoke/generated-case-agent-review.json")
    t.eq(request.cdp_execution.ai_generation.cases, nil)
    t.eq(request.cdp_execution.ai_generation.agent_results, nil)

    local generated = read_file(".testing/runs/module-a-ai-smoke/generated-test-cases.json")
    local gate = read_file(".testing/runs/module-a-ai-smoke/generated-case-gate.json")
    local review = read_file(".testing/runs/module-a-ai-smoke/generated-case-agent-review.json")
    local closure = read_file(".testing/runs/module-a-ai-smoke/ai-test-design-loop.json")
    t.is_true(generated:find('"schema":"testing-runner.generated-test-cases.v1"', 1, true) ~= nil)
    t.is_true(generated:find('"case_count":1', 1, true) ~= nil)
    t.is_true(gate:find('"schema":"testing-runner.generated-case-gate.v1"', 1, true) ~= nil)
    t.is_true(review:find('"schema":"testing-runner.generated-case-agent-review.v1"', 1, true) ~= nil)
    t.is_true(closure:find('"schema":"testing-runner.ai-test-design-loop.v1"', 1, true) ~= nil)
    t.eq(generated:find("secret", 1, true), nil)
    t.eq(closure:find("raw_prompt", 1, true), nil)
    t.eq(closure:find("token", 1, true), nil)

    local trace = graph.require_quiescent(graph.run(terminal_result_event(request), { max_steps = 8 }))
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })
    local publication = graph.require_raise(trace, "test-publication.publication_request").payload
    t.eq(publication.status, "blocked")
    t.eq(publication.severity, "warning")
    t.eq(publication.artifact_root, ".testing/runs/module-a-ai-smoke")
    t.eq(publication.stage_report_path, ".testing/runs/module-a-ai-smoke/stage-report.md")
    t.eq(publication.issue_drafts_path, ".testing/runs/module-a-ai-smoke/issue-drafts.json")
    t.eq(publication.publication_dry_run, true)
  end,
}
