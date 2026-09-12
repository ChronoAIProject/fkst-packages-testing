local fixture_factory = require("testing_runtime.tests.runtime_client_fixture")
local generic_host = require("testing_runtime.generic_host_workflow_qa")
local t = fkst.test

return {
  test_production_reconciles_preauthorization_claim_through_host_runtime = function()
    local fixture = fixture_factory.new({
      ["host-reconcile-preauthorization-claim"] = function(payload)
        return { reconciled = payload.dedup_key == "dedup-reconcile" }
      end,
    })
    local ports = generic_host.production(fixture.options)
    t.eq(ports.reconcile_preauthorization_claim({ dedup_key = "dedup-reconcile" }), true)
    t.eq(ports.reconcile_preauthorization_claim({ dedup_key = "foreign" }), false)
    t.eq(fixture.effect_calls()[1].name, "host-reconcile-preauthorization-claim")
  end,
}
