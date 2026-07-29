local fixture_factory = require("testing_runtime.tests.runtime_client_fixture")
local runtime = require("testing_runtime.qa_publication")
local t = fkst.test

return {
  test_publication_runtime_maps_every_durable_port = function()
    local fixture = fixture_factory.new({
      ["publication-load-ledger"] = { version = 2 },
      ["publication-save-ledger"] = { saved = true },
      ["publication-publish-artifact"] = { status = "published" },
      ["artifact-write"] = { written = true },
      ["publication-write-report"] = { written = true },
      ["artifact-load"] = { value = "artifact" },
    })
    t.eq(runtime.configured(fixture.options), true)
    local ports = runtime.production(fixture.options)
    local root = ".testing/runs/publication-runtime"
    t.eq(ports.load_ledger(root .. "/ledger.json").version, 2)
    t.eq(ports.save_ledger(root .. "/ledger.json", { version = 2 }, 1), true)
    t.eq(ports.publish_artifact({
      artifact_ref = root .. "/report.json", run_id = "run",
    }).status, "published")
    t.eq(ports.write_artifact(root .. "/receipt.json", {}), true)
    t.eq(ports.write_report(root .. "/report.json", {}).written, true)
    t.eq(ports.load_artifact(root .. "/report.json").value, "artifact")
    t.eq(#fixture.effect_calls(), 6)
  end,
}
