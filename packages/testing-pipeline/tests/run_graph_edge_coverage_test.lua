local graph = require("testkit.graph")
local strings = require("contract.strings")

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

local function consensus_proposal_event()
  return {
    queue = "consensus.proposal",
    source_ref = event_source_ref("edge-coverage-consensus"),
    payload = {
      schema = "consensus.proposal.v1",
      proposal_id = "testing-pipeline/ai/edge-coverage",
      dedup_key = "testing-pipeline-ai-edge-coverage",
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
      schema = "testing-pipeline.ai-generation-request.v1",
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
      proposal_id = "testing-pipeline/ai/edge-coverage",
      decision = "approve",
      narrowed_question = "bounded follow-up",
      source_ref = { kind = "testing-ai-generation", ref = ".testing/runs/edge-coverage-ai/ai-context-manifest.json" },
    },
  }
end

local function module_start_event(dedup_key)
  return {
    queue = "module_start",
    source_ref = event_source_ref("edge-coverage-module"),
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = "edge-coverage-module",
      backend = "fkst-native",
      dry_run = false,
      no_browser = true,
      native_argv = { "true" },
      artifact_root = ".testing/runs/edge-coverage-module",
      source_ref = source_ref("edge-coverage-module"),
      dedup_key = dedup_key or "edge-coverage-module-run",
    },
  }
end

return {
  test_run_graph_result_to_publication_edges_are_covered = function()
    local trace = graph.require_quiescent(graph.run(failed_result_event(), { max_steps = 8 }))

    graph.assert_covers(trace, {
      "testing-runner.testing_result -> testing-pipeline.summarize_result",
      "test-artifacts.testing_result -> test-artifacts.summarize",
      "test-artifacts.artifact_summary -> testing-pipeline.prepare_publication",
      "test-publication.artifact_summary -> test-publication.prepare_publication",
    })
  end,

  test_run_graph_module_loop_edges_are_covered = function()
    t.with_command_cassette({
      path = "tests/run-graph-edge-durable-commands.json",
      mode = "record",
    }, function()
      t.mock_command("'true'", {
        stdout = "",
        stderr = "",
        exit_code = 0,
      })

      local run_key = strings.decimal_checksum(tostring(os.getenv("FKST_DURABLE_ROOT") or "edge-coverage"))
      local trace = graph.require_quiescent(graph.run(
        module_start_event("edge-coverage-module-run-" .. run_key),
        { max_steps = 12 }
      ))

      graph.assert_covers(trace, {
        "testing-pipeline.module_start -> testing-pipeline.start_module",
        "module-test-loop.module_loop_request -> module-test-loop.start",
        "testing-runner.module_test_request -> testing-runner.run_module_loop",
      })
    end)
  end,

  test_run_graph_ai_generation_request_routes_to_author = function()
    local trace = graph.require_quiescent(graph.run(ai_generation_event(), { max_steps = 8 }))
    graph.assert_covers(trace, {
      "testing-pipeline.ai_generation_request -> testing-pipeline.ai_generate",
    })
  end,

  test_run_graph_consensus_proposal_routes_to_decide = function()
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/testing-pipeline/consensus-runtime",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("consensus-angle-teleology", {
      stdout = verdict_label .. " approve\n" .. reply_label .. " Edge coverage route approved.\n",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.run(consensus_proposal_event(), { max_steps = 2 })
    graph.assert_covers(trace, {
      "consensus.proposal -> consensus.decide",
    })
  end,

  test_run_graph_consensus_reached_routes_to_ai_orchestration = function()
    local trace = graph.run(consensus_event("consensus.consensus_reached", "consensus.consensus_reached.v1"), { max_steps = 1 })
    graph.assert_covers(trace, {
      "consensus.consensus_reached -> testing-pipeline.ai_consensus",
    })
  end,

  test_run_graph_consensus_converge_routes_to_ai_orchestration = function()
    local trace = graph.run(consensus_event("consensus.consensus_converge", "consensus.consensus_converge.v1"), { max_steps = 1 })
    graph.assert_covers(trace, {
      "consensus.consensus_converge -> testing-pipeline.ai_consensus",
    })
  end,
}
