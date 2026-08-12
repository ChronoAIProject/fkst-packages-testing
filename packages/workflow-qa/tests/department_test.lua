local core = require("core")
local actions = require("departments.actions")
local analysis = require("departments.analysis.main")
local artifacts = require("departments.artifacts.main")
local browser_readiness = require("departments.browser_readiness.main")
local dead_letter = require("departments.dead_letter.main")
local defects = require("departments.defects.main")
local environment = require("departments.environment.main")
local execution = require("departments.execution.main")
local github_comment_in = require("departments.github_comment_in.main")
local github_comment_out = require("departments.github_comment_out.main")
local github_issue_in = require("departments.github_issue_in.main")
local github_issue_out = require("departments.github_issue_out.main")
local github_pr_comment_out = require("departments.github_pr_comment_out.main")
local grant = require("departments.grant.main")
local interrupt = require("departments.interrupt.main")
local module_terminal = require("departments.module_terminal.main")
local plan = require("departments.plan.main")
local publication = require("departments.publication.main")
local seam = require("departments.seam.main")
local start = require("departments.start.main")
local terminal = require("departments.terminal.main")
local testing = require("testkit.testing")
local t = fkst.test

local function includes(values, expected)
  for _, value in ipairs(values or {}) do if value == expected then return true end end
  return false
end

local function with_methods(methods, fn)
  local old = {}
  for name, value in pairs(methods) do old[name] = core[name]; core[name] = value end
  local ok, result = pcall(fn)
  for name, value in pairs(old) do core[name] = value end
  if not ok then error(result, 0) end
  return result
end

local function payload_for(name)
  local source = { kind = "workflow-qa", ref = "run-coverage" }
  local payloads = {
    artifacts = { schema = "test-artifacts.summary.v1", job = "structured-execution", source_ref = source },
    browser_readiness = { schema = "browser-readiness.result.v1", source_ref = source },
    execution = { schema = "testing-runner.result.v1", job = "structured-execution", source_ref = source },
    grant = { status = "granted", source_ref = source },
    module_terminal = { schema = "module-test-loop.terminal.v1", source_ref = source },
    plan = { schema = "testing-runner.structured-plan.result.v1", source_ref = source },
    publication = { schema = "test-publication.qa-publication-receipt.v2" },
  }
  return payloads[name] or {}
end

return {
  test_core_departments_relay_actions_from_their_handlers = function()
    local cases = {
      { name = "start", department = start, method = "start" },
      { name = "environment", department = environment, method = "handle_environment_event" },
      { name = "analysis", department = analysis, method = "handle_analysis_result" },
      { name = "browser_readiness", department = browser_readiness, method = "handle_browser_readiness_result" },
      { name = "module_terminal", department = module_terminal, method = "handle_module_terminal" },
      { name = "plan", department = plan, method = "handle_plan_result" },
      { name = "grant", department = grant, method = "handle_grant_result" },
      { name = "execution", department = execution, method = "handle_execution_result" },
      { name = "artifacts", department = artifacts, method = "handle_artifact_summary" },
      { name = "defects", department = defects, method = "handle_defect_terminal" },
      { name = "publication", department = publication, method = "handle_publication_receipt" },
      { name = "interrupt", department = interrupt, method = "handle_interrupt" },
      { name = "seam", department = seam, method = "redrive" },
    }
    for _, case in ipairs(cases) do
      local called = false
      local output_queue = case.department.spec.produces[1]
      with_methods({
        [case.method] = function(payload)
          called = true
          t.eq(type(payload), "table")
          return { { queue = output_queue, payload = { marker = case.name } } }
        end,
      }, function()
        local trace = testing.run_fake(case.department, {
          queue = case.department.spec.consumes[1],
          payload = payload_for(case.name),
          test_ports = { marker = "ports" },
        })
        t.is_true(called)
        t.eq(#trace.raises, 1)
        t.eq(trace.raises[1].queue, output_queue)
        t.eq(trace.raises[1].payload.marker, case.name)
      end)
    end
  end,

  test_public_handoff_departments_preserve_payloads_and_filters = function()
    local relays = {
      { department = github_comment_out, queue = "github-proxy.github_issue_comment_request" },
      { department = github_issue_in, queue = "test-publication.github_issue_written" },
      { department = github_issue_out, queue = "github-proxy.github_issue_create_request" },
      { department = github_pr_comment_out, queue = "github-proxy.github_pr_comment_request" },
    }
    for _, item in ipairs(relays) do
      local payload = { marker = item.queue }
      local trace = testing.run_fake(item.department, {
        queue = item.department.spec.consumes[1], payload = payload,
      })
      t.eq(trace.raises[1].queue, item.queue)
      t.eq(trace.raises[1].payload.marker, item.queue)
    end

    local accepted = testing.run_fake(github_comment_in, {
      queue = github_comment_in.spec.consumes[1],
      payload = { handoff = { kind = "test-publication.qa-checkpoint" }, marker = "accepted" },
    })
    t.eq(accepted.raises[1].queue, "test-publication.github_comment_written")
    t.eq(accepted.raises[1].payload.marker, "accepted")
    for _, payload in ipairs({ {}, { handoff = {} } }) do
      local rejected = testing.run_fake(github_comment_in, {
        queue = github_comment_in.spec.consumes[1], payload = payload,
      })
      t.eq(#rejected.raises, 0)
    end
  end,

  test_terminal_dead_letter_and_actions_have_bounded_behavior = function()
    local terminal_trace = testing.run_fake(terminal, {
      queue = terminal.spec.consumes[1],
      payload = { schema = "workflow-qa.terminal-request.v2", run_id = "run", status = "passed" },
    })
    t.eq(#terminal_trace.raises, 0)
    local rejected = testing.run_fake(terminal, {
      queue = terminal.spec.consumes[1], payload = { schema = "other" },
    })
    t.eq(#rejected.raises, 0)

    local dead = testing.run_fake(dead_letter, {
      queue = "dead_letter", payload = { reason = "coverage" },
    })
    t.eq(#dead.raises, 0)
    t.is_true(includes(dead_letter.spec.consumes, "dead_letter"))

    local old_raise = raise
    local raised = {}
    raise = function(queue, payload) table.insert(raised, { queue = queue, payload = payload }) end
    actions.raise_all(nil)
    actions.raise_all({
      { queue = "first", payload = { id = 1 } },
      { queue = "second", payload = { id = 2 } },
    })
    raise = old_raise
    t.eq(#raised, 2)
    t.eq(raised[2].payload.id, 2)
  end,

  test_start_department_declares_own_public_seam_and_namespaced_dependencies = function()
    t.eq(start.spec.consumes[1], "qa_run_request")
    t.eq(start.spec.published_seam[1], "qa_run_request")
    t.eq(start.spec.produces[1], "test-publication.qa_checkpoint_request")
    t.eq(start.spec.produces[2], "environment-factory.environment_start")
  end,

  test_environment_department_can_redrive_persisted_structured_progression = function()
    t.is_true(includes(environment.spec.produces, "workflow_qa_execution_grant_request"))
    t.is_true(includes(environment.spec.produces, "testing-runner.structured_execution_request"))
  end,
}
