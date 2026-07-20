local contract = require("contract.testing_design")
local core = require("core")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end
local root = ".testing/runs/testing-design-core"

local function request()
  return {
    schema = contract.schemas.request,
    repository = {
      url = "https://example.invalid/testing-design.git",
      commit_sha = string.rep("a", 40),
      baseline_commit_sha = string.rep("b", 40),
      workspace_ref = { kind = "workspace", ref = "/approved/testing-design" },
      approval_ref = { kind = "artifact", ref = ".testing/approvals/repository.json" },
      approval_sha256 = digest("c"),
    },
    inputs = {},
    artifact_root = root,
    source_ref = { kind = "host-run", ref = "testing-design-core" },
    trace_id = "trace-testing-design-core",
    dedup_key = "dedup-testing-design-core",
  }
end

local function reference(schema, filename, char)
  return {
    schema = contract.schemas.artifact_reference,
    artifact_schema = schema,
    artifact_pointer = root .. "/" .. filename,
    artifact_digest = digest(char),
  }
end

local function runtime_outcome(replayed)
  local key = digest("d")
  return {
    status = "degraded",
    replayed = replayed,
    analysis_key = key,
    context = {
      schema = contract.schemas.context_reference,
      analysis_key = key,
      repository_analysis = reference(contract.schemas.repository_analysis, "repository-analysis.v1.json", "e"),
      requirements_index = reference(contract.schemas.requirements_index, "requirements-index.v1.json", "f"),
      traceability_seed = reference(contract.schemas.traceability_seed, "traceability-seed.v1.json", "1"),
    },
  }
end

return {
  test_analyze_returns_pointer_only_bound_result = function()
    local result = core.analyze(request(), { analyze = function() return runtime_outcome(false) end })
    t.eq(result.schema, contract.schemas.result)
    t.eq(result.status, "degraded")
    t.eq(result.replayed, false)
    t.eq(result.source_ref.ref, "testing-design-core")
    t.eq(result.context.repository_analysis.artifact_pointer, root .. "/repository-analysis.v1.json")
    t.eq(result.requirements_body, nil)
  end,

  test_replay_is_reported_without_changing_context = function()
    local first = core.analyze(request(), { analyze = function() return runtime_outcome(false) end })
    local second = core.analyze(request(), { analyze = function() return runtime_outcome(true) end })
    t.eq(second.replayed, true)
    t.eq(second.analysis_key, first.analysis_key)
    t.eq(second.context.traceability_seed.artifact_digest, first.context.traceability_seed.artifact_digest)
  end,

  test_runtime_cannot_smuggle_fields_or_foreign_context = function()
    local smuggled = runtime_outcome(false); smuggled.raw_document = "hidden"
    t.raises(function() core.analyze(request(), { analyze = function() return smuggled end }) end)
    local foreign = runtime_outcome(false); foreign.context.analysis_key = digest("2")
    t.raises(function() core.analyze(request(), { analyze = function() return foreign end }) end)
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,
}
