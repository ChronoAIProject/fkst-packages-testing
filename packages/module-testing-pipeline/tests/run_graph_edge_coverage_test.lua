local graph = require("testkit.graph")
local ai_orchestration = require("ai_orchestration")

local t = fkst.test
local verdict_label = "\226\159\166FKST:VERDICT\226\159\167"
local reply_label = "\226\159\166FKST:REPLY\226\159\167"

local function source_ref(ref)
  return { kind = "external", ref = ref }
end

local function event_source_ref(reference)
  return { kind = "external", reference = reference }
end

local function failed_result_event()
  return {
    queue = "testing-runner.testing_result",
    source_ref = event_source_ref("edge-coverage-module"),
    payload = {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/edge-coverage-module",
      source_ref = source_ref("edge-coverage-module"),
      dedup_key = "edge-coverage-module-run",
      adapter = { name = "fkst-native", mode = "module-no-browser" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "edge-coverage-module",
        status = "failed",
        mode = "argv",
      },
      exit_code = 1,
      stderr_excerpt = "check failed",
    },
  }
end

local function consensus_request_event()
  return {
    queue = "ai_consensus_request",
    source_ref = event_source_ref("edge-coverage-consensus"),
    payload = {
      schema = "consensus.proposal.v1",
      proposal_id = "module-testing-pipeline/ai/edge-coverage",
      dedup_key = "module-testing-pipeline-ai-edge-coverage",
      title = "Edge coverage consensus proposal",
      body = "Review edge coverage proposal routing.",
      source_ref = { kind = "testing-ai-generation", ref = ".testing/runs/edge-coverage-ai" },
      verdict_mode = "gate",
      angles = { "teleology" },
    },
  }
end

local function ai_generation_event()
  return {
    queue = "ai_generation_request",
    source_ref = event_source_ref("edge-coverage-ai-author"),
    payload = {
      schema = "module-testing-pipeline.ai-generation-request.v1",
      artifact_root = ".testing/runs/edge-coverage-ai-author",
      context_manifest_path = ".testing/runs/edge-coverage-ai-author/ai-context-manifest.json",
      source_ref = source_ref("edge-coverage-ai-author"),
      dedup_key = "edge-coverage-ai-author",
    },
  }
end

local function consensus_event(queue, schema)
  return {
    queue = queue,
    source_ref = event_source_ref("edge-coverage-ai"),
    payload = {
      schema = schema,
      proposal_id = "module-testing-pipeline/ai/edge-coverage",
      decision = "approve",
      narrowed_question = "bounded follow-up",
      source_ref = { kind = "testing-ai-generation", ref = ".testing/runs/edge-coverage-ai/ai-context-manifest.json" },
    },
  }
end

local function module_start_event()
  return {
    queue = "module_start",
    source_ref = event_source_ref("edge-coverage-module"),
    payload = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "edge-coverage-module",
      backend = "fkst-native",
      dry_run = false,
      no_browser = true,
      native_argv = { "true" },
      artifact_root = ".testing/runs/edge-coverage-module",
      source_ref = source_ref("edge-coverage-module"),
      dedup_key = "edge-coverage-module-run",
    },
  }
end

return {
  test_run_graph_result_to_publication_edges_are_covered = function()
    local trace = graph.require_quiescent(graph.run(failed_result_event(), { max_steps = 8 }))

    graph.assert_covers(trace, {
      "testing-runner.testing_result -> module-testing-pipeline.summarize_result",
      "test-artifacts.testing_result -> test-artifacts.summarize",
      "test-artifacts.artifact_summary -> module-testing-pipeline.prepare_publication",
      "test-publication.artifact_summary -> test-publication.prepare_publication",
    })
  end,

  test_run_graph_module_loop_edges_are_covered = function()
    t.mock_command("'true'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.require_quiescent(graph.run(module_start_event(), { max_steps = 12 }))

    graph.assert_covers(trace, {
      "module-testing-pipeline.module_start -> module-testing-pipeline.start_module",
      "module-test-loop.module_loop_request -> module-test-loop.start",
      "testing-runner.module_test_request -> testing-runner.run_module_loop",
    })
  end,

  test_run_graph_ai_generation_request_routes_to_author = function()
    local trace = graph.require_quiescent(graph.run(ai_generation_event(), { max_steps = 8 }))
    graph.assert_covers(trace, {
      "module-testing-pipeline.ai_generation_request -> module-testing-pipeline.ai_generate",
    })
  end,

  test_run_graph_consensus_request_routes_to_call = function()
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/module-testing-pipeline/consensus-runtime",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("consensus-angle-teleology", {
      stdout = ai_orchestration.json_encode({
        type = "item.completed",
        item = {
          type = "agent_message",
          text = verdict_label .. " approve\n" .. reply_label .. " Edge coverage route approved.\n",
        },
      }) .. "\n",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.run(consensus_request_event(), { max_steps = 2 })
    graph.assert_covers(trace, {
      "module-testing-pipeline.ai_consensus_request -> module-testing-pipeline.ai_consensus_call",
      "module-testing-pipeline.ai_consensus_result -> module-testing-pipeline.ai_consensus",
    })
  end,

  test_run_graph_consensus_reached_routes_to_ai_orchestration = function()
    local trace = graph.run(consensus_event("ai_consensus_result", "consensus.consensus_reached.v1"), { max_steps = 1 })
    graph.assert_covers(trace, {
      "module-testing-pipeline.ai_consensus_result -> module-testing-pipeline.ai_consensus",
    })
  end,

  test_run_graph_consensus_converge_routes_to_ai_orchestration = function()
    local trace = graph.run(consensus_event("ai_consensus_result", "consensus.consensus_converge.v1"), { max_steps = 1 })
    graph.assert_covers(trace, {
      "module-testing-pipeline.ai_consensus_result -> module-testing-pipeline.ai_consensus",
    })
  end,
}
