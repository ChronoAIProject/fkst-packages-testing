local graph = require("testkit.graph")

local function trace(queue)
  return graph.run({
    queue = queue,
    source_ref = { kind = "external", reference = "workflow-qa-edge" },
    payload = {},
  }, { max_steps = 8 })
end

return {
  test_declared_cross_package_edges_are_routable = function()
    graph.assert_covers(trace("environment-factory.environment_finalize"), {
      "environment-factory.environment_finalize -> environment-factory.finalize",
    })
    graph.assert_covers(trace("environment-factory.environment_interrupt"), {
      "environment-factory.environment_interrupt -> environment-factory.interrupt",
    })
    graph.assert_covers(trace("environment-factory.environment_result"), {
      "environment-factory.environment_result -> workflow-qa.environment",
    })
    graph.assert_covers(trace("environment-factory.environment_start"), {
      "environment-factory.environment_start -> environment-factory.start",
    })
    graph.assert_covers(trace("test-artifacts.artifact_summary"), {
      "test-artifacts.artifact_summary -> workflow-qa.artifacts",
    })
    graph.assert_covers(trace("test-publication.defect_preparation_request"), {
      "test-publication.defect_preparation_request -> test-publication.prepare_product_defects",
    })
    graph.assert_covers(trace("test-publication.defect_publication_request"), {
      "test-publication.defect_publication_request -> test-publication.publish_product_defects",
    })
    graph.assert_covers(trace("test-publication.defect_publication_terminal"), {
      "test-publication.defect_publication_terminal -> workflow-qa.defects",
    })
    graph.assert_covers(trace("test-publication.qa_checkpoint_request"), {
      "test-publication.qa_checkpoint_request -> test-publication.record_qa_checkpoint",
    })
    graph.assert_covers(trace("test-publication.qa_finalize_request"), {
      "test-publication.qa_finalize_request -> test-publication.finalize_qa_run",
    })
    graph.assert_covers(trace("test-publication.qa_publication_receipt"), {
      "test-publication.qa_publication_receipt -> workflow-qa.publication",
    })
    graph.assert_covers(trace("testing-design.analysis_request"), {
      "testing-design.analysis_request -> testing-design.start",
    })
    graph.assert_covers(trace("testing-design.analysis_result"), {
      "testing-design.analysis_result -> workflow-qa.analysis",
    })
    graph.assert_covers(trace("browser-readiness.browser_readiness_check"), {
      "browser-readiness.browser_readiness_check -> browser-readiness.check_readiness",
    })
    graph.assert_covers(trace("browser-readiness.browser_readiness_result"), {
      "browser-readiness.browser_readiness_result -> workflow-qa.browser_readiness",
    })
    graph.assert_covers(trace("testing-runner.testing_result"), {
      "testing-runner.testing_result -> module-test-loop.result",
    })
    graph.assert_covers(trace("module-test-loop.module_loop_terminal"), {
      "module-test-loop.module_loop_terminal -> module-testing-pipeline.summarize_terminal",
      "module-test-loop.module_loop_terminal -> workflow-qa.module_terminal",
    })
    graph.assert_covers(trace("testing-runner.structured_plan_request"), {
      "testing-runner.structured_plan_request -> testing-runner.compile_structured_plan",
    })
    graph.assert_covers(trace("testing-runner.structured_plan_result"), {
      "testing-runner.structured_plan_result -> workflow-qa.plan",
    })
    graph.assert_covers(trace("testing-runner.structured_execution_request"), {
      "testing-runner.structured_execution_request -> testing-runner.run_structured_execution",
    })
    graph.assert_covers(trace("testing-runner.ai_browser_control_request"), {
      "testing-runner.ai_browser_control_request -> testing-runner.run_ai_browser_control",
    })
    graph.assert_covers(trace("testing-runner.testing_result"), {
      "testing-runner.testing_result -> workflow-qa.execution",
    })
    graph.assert_covers(trace("test-publication.github_comment_written"), {
      "test-publication.github_comment_written -> test-publication.acknowledge_qa_publication",
    })
    graph.assert_covers(trace("test-publication.github_issue_comment_request"), {
      "test-publication.github_issue_comment_request -> workflow-qa.github_comment_out",
    })
    graph.assert_covers(trace("test-publication.github_issue_create_request"), {
      "test-publication.github_issue_create_request -> workflow-qa.github_issue_out",
    })
    graph.assert_covers(trace("test-publication.github_issue_written"), {
      "test-publication.github_issue_written -> test-publication.acknowledge_product_defect",
    })
    graph.assert_covers(trace("github-proxy.github_issue_label_request"), {
      "github-proxy.github_issue_label_request -> github-proxy.github_issue_label",
    })
    graph.assert_covers(trace("github-proxy.github_pr_comment_request"), {
      "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
    })
  end,
}
