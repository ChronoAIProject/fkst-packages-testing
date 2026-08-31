local core_fixtures = require("testkit.devloop_core_fixtures")
local devloop_fixtures = require("testkit.devloop_fixtures")
local helper_fixtures = require("testkit.devloop_helpers_fixtures")
local pr_fixtures = require("testkit.devloop_pr_fixtures")
local worktree_fixtures = require("testkit.devloop_worktree_fixtures")
local gh_argv = require("testkit.gh_argv_mock")
local graph = require("testkit.graph")
local namespaced = require("testkit.namespaced_dispatch_conformance")
local saga_conformance = require("testkit.saga_conformance")
local t = fkst.test

local function noop() end

local function fixture_base()
  return {
    t = t,
    core = {},
    action_label = "ACTION",
    reason_label = "REASON",
    json_string = function(value) return tostring(value) end,
  }
end

return {
  test_fixture_factories_require_declared_dependencies = function()
    t.raises(function() core_fixtures.new({}) end)

    local deps = {}
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.core = {}
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.entity_read_mocks = {}
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.devloop_base = { configure_trusted_bot_login = noop }
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.payloads_builders = {}
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.conv_reconcile = {}
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.m_builders = {}
    t.raises(function() devloop_fixtures.new(deps) end)
    deps.pr_safety = {}
    local fixtures = devloop_fixtures.new(deps)
    t.raises(function() fixtures.run_result({}) end)

    deps = {}
    t.raises(function() helper_fixtures.new(deps) end)
    deps.entity_lib = {}
    t.raises(function() helper_fixtures.new(deps) end)
    deps.base = {}
    t.raises(function() helper_fixtures.new(deps) end)
    deps.pr = {}
    t.raises(function() helper_fixtures.new(deps) end)
    deps.worktree = {}
    t.raises(function() helper_fixtures.new(deps) end)

    deps = {}
    t.raises(function() pr_fixtures.new(deps) end)
    deps.entity_lib = {}
    t.raises(function() pr_fixtures.new(deps) end)
    deps.base = fixture_base()
    t.raises(function() pr_fixtures.new(deps) end)
    deps.entity_read_mocks = {}
    t.raises(function() pr_fixtures.new(deps) end)
    deps.m_builders = {}
    t.raises(function() pr_fixtures.new(deps) end)
    deps.pr_safety = {}
    deps.include_high_risk_helpers = true
    local pr = pr_fixtures.new(deps)
    t.raises(function() pr.high_risk_paths_digest() end)

    deps = {}
    t.raises(function() worktree_fixtures.new(deps) end)
    deps.devloop_base = { implement_worktree_path = function() return "/tmp/fkst-coverage/worktree" end }
    t.raises(function() worktree_fixtures.new(deps) end)
    deps.base_ids = {}
    t.raises(function() worktree_fixtures.new(deps) end)
  end,

  test_worktree_fixture_reports_directory_creation_failure = function()
    local fixtures = worktree_fixtures.new({
      devloop_base = { implement_worktree_path = function() return "/tmp/fkst-coverage/worktree" end },
      base_ids = {},
      base = fixture_base(),
      enable_substrate_pin_refresh = true,
    })
    local previous_execute = os.execute
    os.execute = function() return false end
    local ok, err = pcall(fixtures.mock_fresh_implement_worktree, "/tmp/fkst-coverage")
    os.execute = previous_execute
    t.eq(ok, false)
    t.is_true(tostring(err):find("mkdir-failed", 1, true) ~= nil)
  end,

  test_gh_and_graph_helpers_reject_invalid_inputs = function()
    local core = {}
    gh_argv.install(t, core)
    t.raises(function() core.gh_issue_list_observe_cmd("owner/repo", "label", 0, false) end)
    t.raises(function() graph.assert_covers({ steps = {} }, { "queue -> package.department" }) end)
    t.raises(function() graph.require_raise({ steps = {} }, "missing") end)
  end,

  test_namespaced_dispatch_validation_fails_closed = function()
    t.raises(function() namespaced.loaded_departments({ "departments/start/main.lua" }) end)

    local base = {
      t = t,
      package_name = "testing-runner",
      package_root = "packages/testing-runner",
      payload_for_queue = function() return {} end,
    }
    local first_path = "departments/compile_structured_plan/main.lua"

    base.departments = { [first_path] = {} }
    t.raises(function() namespaced.assert_all_consumed_queues_route(base) end)

    base.departments = {
      [first_path] = {
        spec = { consumes = { "structured_plan_request" }, produces = {} },
      },
    }
    t.raises(function() namespaced.assert_all_consumed_queues_route(base) end)

    base.departments = {}
    t.raises(function() namespaced.assert_all_consumed_queues_route(base) end)

    local previous_popen = io.popen
    io.popen = function()
      return {
        lines = function() return function() return nil end end,
        close = function() return false end,
      }
    end
    local ok, err = pcall(namespaced.assert_all_consumed_queues_route, base)
    io.popen = previous_popen
    t.eq(ok, false)
    t.is_true(tostring(err):find("department discovery failed", 1, true) ~= nil)
  end,

  test_saga_conformance_rejects_malformed_definitions = function()
    local valid_step = {
      id = "step",
      effect = "comment",
      request_queue = "request",
      post_conditions = { { id = "receipt", kind = "trusted-comment-marker" } },
    }

    t.raises(function() saga_conformance.assert_external_effect_saga(nil) end)
    t.raises(function() saga_conformance.assert_external_effect_saga({}) end)
    t.raises(function() saga_conformance.assert_external_effect_saga({ id = "saga", steps = {} }) end)
    t.raises(function() saga_conformance.assert_external_effect_saga({ id = "saga", steps = { false } }) end)
    t.raises(function()
      saga_conformance.assert_external_effect_saga({ id = "saga", steps = { {} } })
    end)
    t.raises(function()
      saga_conformance.assert_external_effect_saga({ id = "saga", steps = { { id = "step" } } })
    end)
    t.raises(function()
      saga_conformance.assert_external_effect_saga({
        id = "saga",
        steps = { { id = "step", effect = "effect" } },
      })
    end)
    t.raises(function()
      saga_conformance.assert_external_effect_saga({
        id = "saga",
        steps = { { id = "step", effect = "effect", request_queue = "request", post_conditions = {} } },
      })
    end)
    t.raises(function()
      local step = { id = "step", effect = "effect", request_queue = "request", post_conditions = { false } }
      saga_conformance.assert_external_effect_saga({ id = "saga", steps = { step } })
    end)
    t.raises(function()
      local step = { id = "step", effect = "effect", request_queue = "request", post_conditions = { { kind = "kind" } } }
      saga_conformance.assert_external_effect_saga({ id = "saga", steps = { step } })
    end)
    t.raises(function()
      local step = { id = "step", effect = "effect", request_queue = "request", post_conditions = { { id = "condition" } } }
      saga_conformance.assert_external_effect_saga({ id = "saga", steps = { step } })
    end)
    saga_conformance.assert_external_effect_saga({ id = "saga", steps = { valid_step } })
  end,

  test_saga_conformance_rejects_unproven_effects = function()
    t.raises(function() saga_conformance.assert_external_effect_post_condition(nil, nil) end)
    t.raises(function()
      saga_conformance.assert_external_effect_post_condition({ id = "condition", kind = "unknown" }, {})
    end)
    t.raises(function()
      saga_conformance.assert_external_effect_post_condition(
        {
          id = "condition",
          kind = "github-add-blocked-by-edge",
          forbidden_fields = { "forbidden" },
        },
        { command = "mutation addBlockedBy issueId: blockingIssueId: forbidden" }
      )
    end)
    t.raises(function()
      saga_conformance.assert_external_effect_post_condition(
        { id = "condition", kind = "trusted-comment-marker" },
        {}
      )
    end)

    t.raises(function() saga_conformance.assert_progress(t, nil) end)
    t.raises(function() saga_conformance.assert_progress(t, {}) end)
    t.raises(function()
      saga_conformance.assert_progress(t, { first = function() return {} end })
    end)
    t.raises(function()
      saga_conformance.assert_progress(t, {
        first = function() return {} end,
        is_write_class = function() return false end,
      })
    end)

    t.raises(function() saga_conformance.assert_idempotent(t, nil) end)
    t.raises(function() saga_conformance.assert_idempotent(t, {}) end)
    t.raises(function()
      saga_conformance.assert_idempotent(t, { first = function() return {} end })
    end)
    t.raises(function()
      saga_conformance.assert_idempotent(t, {
        first = function() return {} end,
        second = function() return {} end,
      })
    end)
    t.raises(function()
      saga_conformance.assert_idempotent(t, {
        first = function() return {} end,
        second = function() return {} end,
        is_write_class = function() return false end,
      })
    end)
    t.raises(function()
      saga_conformance.assert_idempotent(t, {
        first = function() return { raises = { {} } } end,
        second = function() return { raises = { {} } } end,
        is_write_class = function() return false end,
      })
    end)
  end,
}
