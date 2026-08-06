local graph = require("testkit.graph")

local function trace(queue)
  return graph.run({
    queue = queue,
    source_ref = { kind = "external", reference = "local-qa-host-adapter-edge" },
    payload = {},
  }, { max_steps = 8 })
end

return {
  test_declared_cross_package_edges_are_routable = function()
    graph.assert_covers(trace("workflow-qa.qa_run_request"), {
      "workflow-qa.qa_run_request -> workflow-qa.start",
    })
    graph.assert_covers(trace("workflow-qa.execution_grant_result"), {
      "workflow-qa.execution_grant_result -> workflow-qa.grant",
    })
    graph.assert_covers(trace("workflow-qa.workflow_qa_execution_grant_request"), {
      "workflow-qa.workflow_qa_execution_grant_request -> local-qa-host-adapter.execution_grant",
    })
    graph.assert_covers(trace("workflow-qa.workflow_qa_terminal_request"), {
      "workflow-qa.workflow_qa_terminal_request -> local-qa-host-adapter.terminal",
    })
  end,
}
