local fixture_factory = require("testing_runtime.tests.runtime_client_fixture")
local generic_host = require("testing_runtime.generic_host_workflow_qa")
local workflow_runtime = require("testing_runtime.workflow_qa")
local t = fkst.test

local function options(responses)
  local fixture = fixture_factory.new(responses)
  return fixture.options, fixture
end

return {
  test_workflow_runtime_maps_every_durable_port = function()
    local configured, fixture = options({
      ["workflow-load-state"] = { state = "running" },
      ["workflow-load-run"] = { run_id = "run-1" },
      ["workflow-load-run-by-id"] = { run_id = "run-2" },
      ["workflow-list-pending-runs"] = { { run_id = "run-3" } },
      ["workflow-save-state"] = { saved = true },
      ["artifact-load"] = { value = "artifact" },
      ["artifact-write"] = { written = true },
      ["artifact-digest"] = { digest = string.rep("a", 64) },
    })
    t.eq(workflow_runtime.configured(configured), true)
    local ports = workflow_runtime.production(configured)
    local root = ".testing/runs/workflow-runtime"
    t.eq(ports.load_state(root .. "/state.json").state, "running")
    t.eq(ports.load_run("trace", "dedup").run_id, "run-1")
    t.eq(ports.load_run_by_id("run-2").run_id, "run-2")
    t.eq(ports.list_pending_runs(4)[1].run_id, "run-3")
    t.eq(ports.save_state(root .. "/state.json", { state = "running" }, 2), true)
    t.eq(ports.load_artifact(root .. "/artifact.json").value, "artifact")
    t.eq(ports.write_artifact(root .. "/artifact.json", {}), true)
    t.eq(ports.artifact_digest(root .. "/artifact.json"), string.rep("a", 64))
    t.eq(#fixture.effect_calls(), 8)
  end,

  test_generic_host_runtime_maps_every_adapter_port = function()
    local intake_claim = {
      status = "claimed",
      claim_id = "local-qa-intake-claim",
      replayed = false,
    }
    local configured, fixture = options({
      ["artifact-load"] = { value = "artifact" },
      ["artifact-write"] = { written = true },
      ["artifact-digest"] = { digest = string.rep("b", 64) },
      ["host-claim-qa-run-intake"] = intake_claim,
      ["host-claim-preauthorization"] = { claimed = true },
      ["host-grant-values"] = { grant = "value" },
      ["host-record-terminal"] = { recorded = true },
    })
    t.eq(generic_host.configured(configured), true)
    local ports = generic_host.production(configured)
    local root = ".testing/runs/generic-host"
    t.eq(ports.load_artifact(root .. "/artifact.json").value, "artifact")
    t.eq(ports.write_artifact(root .. "/artifact.json", {}), true)
    t.eq(ports.artifact_digest(root .. "/artifact.json"), string.rep("b", 64))
    local intake_request = { run_id = "local-qa-intake-runtime" }
    local claim = ports.claim_qa_run_intake(intake_request)
    t.eq(claim.status, intake_claim.status)
    t.eq(claim.claim_id, intake_claim.claim_id)
    t.eq(claim.replayed, intake_claim.replayed)
    t.eq(intake_request.run_id, "local-qa-intake-runtime")
    t.eq(intake_request.request_id, nil)
    t.eq(intake_request.runtime_config_ref, nil)
    t.eq(ports.claim_preauthorization({ dedup_key = "dedup" }).claimed, true)
    t.eq(ports.grant_values({ dedup_key = "dedup" }, {}).grant, "value")
    t.eq(ports.record_terminal({ run_id = "run" }), true)
    local effects = fixture.effect_calls()
    t.eq(#effects, 7)
    local intake_effects = 0
    for _, effect in ipairs(effects) do
      if effect.name == "host-claim-qa-run-intake" then intake_effects = intake_effects + 1 end
    end
    t.eq(intake_effects, 1)
    t.eq(effects[4].name, "host-claim-qa-run-intake")
    t.eq(effects[4].payload.run_id, intake_request.run_id)
    t.is_true(effects[4].request.argv[7]:find(
      "host-claim-qa-run-intake-local-qa-intake-runtime-", 1, true) ~= nil)
  end,
}
