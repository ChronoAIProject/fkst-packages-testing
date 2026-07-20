local contract = require("contract.testing_design")
local graph = require("testkit.graph")
local json = require("testing_runtime.json")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end
local root = ".testing/runs/testing-design-graph"
local key = digest("d")

local function reference(schema, filename, char)
  return {
    schema = contract.schemas.artifact_reference,
    artifact_schema = schema,
    artifact_pointer = root .. "/" .. filename,
    artifact_digest = digest(char),
  }
end

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
    source_ref = { kind = "host-run", ref = "testing-design-graph" },
    trace_id = "trace-testing-design-graph",
    dedup_key = "dedup-testing-design-graph",
  }
end

return {
  test_analysis_request_emits_pointer_only_result = function()
    t.mock_command("node packages/testing-design/bin/testing-design-runtime.js analyze-env", {
      exit_code = 0,
      stdout = json.encode({
        ok = true,
        result = {
          status = "complete", replayed = false, analysis_key = key,
          context = {
            schema = contract.schemas.context_reference, analysis_key = key,
            repository_analysis = reference(contract.schemas.repository_analysis, "repository-analysis.v1.json", "e"),
            requirements_index = reference(contract.schemas.requirements_index, "requirements-index.v1.json", "f"),
            traceability_seed = reference(contract.schemas.traceability_seed, "traceability-seed.v1.json", "1"),
          },
        },
      }),
    })
    local trace = graph.run({
      queue = "analysis_request",
      source_ref = { kind = "external", reference = "testing-design" },
      payload = request(),
    }, { max_steps = 4 })
    graph.require_delivery(trace, { queue = "analysis_request", consumer = "start" })
    local result = graph.require_raise(trace, "analysis_result").payload
    t.eq(result.schema, contract.schemas.result)
    t.eq(result.context.requirements_index.artifact_digest, digest("f"))
    t.eq(result.repository_content, nil)
  end,

  test_keepalive_and_dead_letter_departments_accept_their_public_queues = function()
    local keepalive = graph.run({
      queue = "analysis_keepalive_tick",
      source_ref = { kind = "external", reference = "testing-design-keepalive" },
      payload = {},
    }, { max_steps = 2 })
    graph.require_delivery(keepalive, { queue = "analysis_keepalive_tick", consumer = "seam" })

    local dead = graph.run({
      queue = "dead_letter",
      source_ref = { kind = "external", reference = "testing-design-dead-letter" },
      payload = {
        delivery_id = "delivery-testing-design",
        queue = "analysis_request",
        dept = "start",
        source_ref = { kind = "host-run", ref = "testing-design" },
        dedup_key = "dedup-testing-design",
        attempt = 1,
        error = "fixture failure",
      },
    }, { max_steps = 2 })
    graph.require_delivery(dead, { queue = "dead_letter", consumer = "dead_letter" })
  end,
}
