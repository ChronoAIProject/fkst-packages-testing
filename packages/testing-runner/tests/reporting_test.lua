local core = require("core")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function request(overrides)
  overrides = overrides or {}
  local value = {
    schema = "testing-runner.module-test-loop.request.v1",
    backend = "fkst-native",
    module = "module-a",
    dry_run = false,
    ui_loop = {
      base_url = fixture_base_url,
      allowed_origins = { fixture_origin },
      cdp_readiness_ref = "cdp-ready",
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = fixture_base_url .. "/dashboard?secret=value#state",
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
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready" },
      },
    },
    artifact_root = ".testing/runs/module-a-report",
  }
  for key, item in pairs(overrides) do value[key] = item end
  return value
end

return {
  test_native_ui_loop_writes_stage_report_and_issue_draft_artifacts = function()
    local written = {}
    local result = core.run("module", request({
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }))

    t.eq(result.status, "blocked")
    t.eq(result.native_summary.stage_report_path, ".testing/runs/module-a-report/stage-report.md")
    t.eq(result.native_summary.issue_drafts_path, ".testing/runs/module-a-report/issue-drafts.json")
    t.eq(result.native_summary.publication_dry_run, true)

    local report = written[".testing/runs/module-a-report/stage-report.md"]
    t.is_true(report:find("Discovered modules", 1, true) ~= nil)
    t.is_true(report:find("Coverage status", 1, true) ~= nil)
    t.is_true(report:find("AI generated coverage", 1, true) ~= nil)
    t.is_true(report:find("Agent generation: not-recorded", 1, true) ~= nil)
    t.is_true(report:find("Agent review: not-recorded", 1, true) ~= nil)
    t.is_true(report:find("AI test design loop: not-recorded", 1, true) ~= nil)
    t.is_true(report:find("Executed user-facing scenarios", 1, true) ~= nil)
    t.is_true(report:find("Failed assertions", 1, true) ~= nil)
    t.is_true(report:find("No failed typed assertion was recorded", 1, true) ~= nil)
    t.is_true(report:find("Screenshot index", 1, true) ~= nil)
    t.is_true(report:find("No failure screenshot was recorded", 1, true) ~= nil)
    t.is_true(report:find("No bounded browser/CDP cases were executed", 1, true) ~= nil)
    t.is_true(report:find("Publication handoff: dry-run pointer handoff only", 1, true) ~= nil)
    t.eq(report:find("secret", 1, true), nil)

    local drafts = written[".testing/runs/module-a-report/issue-drafts.json"]
    t.is_true(drafts:find('"publication_dry_run":true', 1, true) ~= nil)
    t.is_true(drafts:find('"external_write":false', 1, true) ~= nil)
    t.is_true(drafts:find('"stage_report_path":".testing/runs/module-a-report/stage-report.md"', 1, true) ~= nil)

    local bundle = written[".testing/runs/module-a-report/evidence-bundle.json"]
    t.is_true(bundle:find('"stage_report_path":".testing/runs/module-a-report/stage-report.md"', 1, true) ~= nil)
    t.is_true(bundle:find('"issue_drafts_path":".testing/runs/module-a-report/issue-drafts.json"', 1, true) ~= nil)
    t.is_true(bundle:find('"ai_generation_path":".testing/runs/module-a-report/evidence/ai-generation.json"', 1, true) ~= nil)
    t.is_true(bundle:find('"ai_test_design_loop_path":".testing/runs/module-a-report/ai-test-design-loop.json"', 1, true) ~= nil)

    local ai_generation = written[".testing/runs/module-a-report/evidence/ai-generation.json"]
    t.is_true(ai_generation:find('"schema":"testing-runner.native-evidence-ai-generation.v1"', 1, true) ~= nil)
    t.is_true(ai_generation:find('"generated_case_count":0', 1, true) ~= nil)
    t.is_true(ai_generation:find('"status":"disabled"', 1, true) ~= nil)
    t.eq(ai_generation:find("model_transcript", 1, true), nil)
    t.eq(ai_generation:find("raw_prompt", 1, true), nil)
    t.eq(written[".testing/runs/module-a-report/ai-context-manifest.json"], nil)
    t.eq(written[".testing/runs/module-a-report/generated-test-cases.json"], nil)
    t.eq(written[".testing/runs/module-a-report/generated-case-gate.json"], nil)
    t.eq(written[".testing/runs/module-a-report/ai-agent-generation.json"], nil)
    t.eq(written[".testing/runs/module-a-report/generated-case-agent-review.json"], nil)
    t.eq(written[".testing/runs/module-a-report/ai-test-design-loop.json"], nil)

    local screenshot_index = written[".testing/runs/module-a-report/evidence/screenshot-index.json"]
    t.is_true(screenshot_index:find('"ref_count":0', 1, true) ~= nil)

    local metadata = written[".testing/runs/module-a-report/metadata.json"]
    t.is_true(metadata:find('"stage_report_path":".testing/runs/module-a-report/stage-report.md"', 1, true) ~= nil)
    t.is_true(metadata:find("Executed user-facing scenarios", 1, true) == nil)
    t.is_true(metadata:find("recommendations", 1, true) == nil)
  end,
}
