local fixture_factory = require("testing_runtime.tests.runtime_client_fixture")
local runtime = require("testing_runtime.qa_publication")
local t = fkst.test

return {
  test_publication_runtime_maps_every_durable_port = function()
    local fixture = fixture_factory.new({
      ["sha256-bytes"] = {
        sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      },
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
    t.eq(ports.sha256_bytes("abc", root .. "/publication"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    local hash_call = fixture.effect_calls()[1]
    t.eq(hash_call.payload.bytes, "abc")
    t.eq(hash_call.payload.artifact_root, nil)
    t.is_true(hash_call.request.argv[7]:find(root .. "/", 1, true) == 1)
    t.raises(function() ports.sha256_bytes("abc", "outside") end)
    t.raises(function() ports.sha256_bytes(string.rep("a", 1024 * 1024 + 1), root) end)
    t.eq(ports.load_ledger(root .. "/ledger.json").version, 2)
    t.eq(ports.save_ledger(root .. "/ledger.json", { version = 2 }, 1), true)
    t.eq(ports.publish_artifact({
      artifact_ref = root .. "/report.json", run_id = "run",
    }).status, "published")
    t.eq(ports.write_artifact(root .. "/receipt.json", {}), true)
    t.eq(ports.write_report(root .. "/report.json", {}).written, true)
    t.eq(ports.load_artifact(root .. "/report.json").value, "artifact")
    t.eq(#fixture.effect_calls(), 7)
  end,
}
