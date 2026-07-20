local graph = require("testkit.graph")
local t = fkst.test

return {
  test_structured_execution_result_reaches_publication_with_case_result_pointers = function()
    local artifact_root = ".testing/runs/structured-graph/execution"
    local trace = graph.require_quiescent(graph.run({
      queue = "testing-runner.testing_result",
      source_ref = { kind = "external", reference = "structured-graph" },
      payload = {
        schema = "testing-runner.result.v1",
        job = "structured-execution",
        status = "passed",
        artifact_root = artifact_root,
        source_ref = { kind = "workflow-qa", ref = "run-graph" },
        trace_id = "trace-structured-graph",
        dedup_key = "dedup-structured-graph",
        adapter = { name = "fkst-native", mode = "structured-api-cli" },
        native_summary = {
          schema = "testing-runner.structured-execution-summary.v1",
          status = "passed",
          classification = "passed",
          mode = "structured-api-cli",
          artifact_root = artifact_root,
          test_plan_path = artifact_root .. "/test-plan.json",
          execution_path = artifact_root .. "/execution.json",
          case_results_path = artifact_root .. "/case-results.json",
          case_count = 2,
          passed_count = 2,
          failed_count = 0,
          skipped_count = 0,
          error_count = 0,
          replayed = false,
        },
      },
    }, { max_steps = 6 }))

    graph.require_delivery(trace, { queue = "test-artifacts.testing_result", consumer = "test-artifacts.summarize" })
    graph.require_delivery(trace, { queue = "test-publication.artifact_summary", consumer = "test-publication.prepare_publication" })
    local publication = graph.require_raise(trace, "test-publication.publication_request").payload
    t.eq(publication.status, "passed")
    t.eq(publication.job, "structured-execution")
    t.eq(publication.artifact_root, artifact_root)
    t.eq(publication.metadata_path, artifact_root .. "/metadata.json")
    t.eq(publication.case_results_path, artifact_root .. "/case-results.json")
    t.eq(publication.execution_path, artifact_root .. "/execution.json")
  end,
}
