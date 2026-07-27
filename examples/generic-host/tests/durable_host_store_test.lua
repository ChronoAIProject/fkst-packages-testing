local Store = require("host_durable_store")
local t = fkst.test

local function cleanup(path)
  os.execute("rm -rf " .. string.format("%q", path))
end

local function runtime_cli()
  local candidates = {
    "examples/generic-host/bin/durable-host-store.js",
    "packages/generic-host/bin/durable-host-store.js",
  }
  for _, path in ipairs(candidates) do
    local handle = io.open(path, "rb")
    if handle ~= nil then handle:close() return path end
  end
  error("generic-host durable store test: runtime CLI is unavailable")
end

return {
  test_durable_store_enforces_immutable_cas_claim_and_artifact_bindings = function()
    local root = os.tmpname() .. "-generic-host-durable-store"
    cleanup(root)
    local store = Store.new(root, runtime_cli())
    local ok, err = pcall(function()
      local first = store:immutable("workflow-qa/requests/run-1", { run_id = "run-1" })
      t.eq(first.written, true)
      t.eq(store:immutable("workflow-qa/requests/run-1", { run_id = "run-1" }).replayed, true)
      t.eq(store:immutable("workflow-qa/requests/run-1", { run_id = "run-2" }).replayed, false)

      local saved = store:cas("workflow-qa/state/run-1", { version = 1, phase = "pending" }, 0)
      t.eq(saved.saved, true)
      local stale = store:cas("workflow-qa/state/run-1", { version = 1, phase = "foreign" }, 0)
      t.eq(stale.saved, false)
      t.eq(stale.stale, true)
      t.eq(stale.version, 1)

      local claim = store:claim("testing-runner/replay/grant-1", {
        status = "claimed",
        claim_id = "claim-1",
        binding = { grant_id = "grant-1", trace_id = "trace-1" },
      })
      t.eq(claim.claimed, true)
      t.eq(claim.replayed, false)
      t.eq(store:claim("testing-runner/replay/grant-1", {
        status = "claimed",
        claim_id = "claim-1",
        binding = { grant_id = "grant-1", trace_id = "trace-1" },
      }).replayed, true)
      t.eq(store:claim("testing-runner/replay/grant-1", {
        status = "claimed",
        claim_id = "claim-2",
        binding = { grant_id = "grant-1", trace_id = "foreign" },
      }).claimed, false)

      local artifact = store:write_artifact(".testing/runs/run-1/execution.json", "{\"status\":\"passed\"}\n")
      t.eq(artifact.written, true)
      t.eq(#artifact.digest, 64)
      t.eq(store:read_artifact(".testing/runs/run-1/execution.json").digest, artifact.digest)
      t.eq(store:write_artifact(".testing/runs/run-1/execution.json", "changed\n").written, false)

      local complete = store:complete_replay("testing-runner/replay/grant-1", "claim-1", {
        result_ref = ".testing/runs/run-1/execution.json",
        result_sha256 = artifact.digest,
        trace_id = "trace-1",
      })
      t.eq(complete.completed, true)
      t.eq(complete.replayed, false)
      t.eq(store:complete_replay("testing-runner/replay/grant-1", "claim-1", {
        result_ref = ".testing/runs/run-1/execution.json",
        result_sha256 = artifact.digest,
        trace_id = "trace-1",
      }).replayed, true)
      t.eq(store:complete_replay("testing-runner/replay/grant-1", "foreign", {
        result_ref = ".testing/runs/run-1/execution.json",
        result_sha256 = artifact.digest,
      }).completed, false)
    end)
    cleanup(root)
    if not ok then error(err, 0) end
  end,
}
