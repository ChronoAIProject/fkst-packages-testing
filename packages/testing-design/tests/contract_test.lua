local contract = require("contract.testing_design")
local t = fkst.test

local function digest(char) return string.rep(char or "a", 64) end

local function input(kind)
  return {
    kind = kind or "requirements",
    source_ref = { kind = "artifact", ref = ".testing/inputs/requirements.md" },
    revision = "requirements-v1",
    content_sha256 = digest("a"),
    approval_ref = { kind = "artifact", ref = ".testing/approvals/requirements.json" },
    approval_sha256 = digest("b"),
  }
end

local function request()
  return {
    schema = contract.schemas.request,
    repository = {
      url = "https://example.invalid/testing-design.git",
      commit_sha = string.rep("c", 40),
      baseline_commit_sha = string.rep("d", 40),
      workspace_ref = { kind = "workspace", ref = "/approved/testing-design" },
      approval_ref = { kind = "artifact", ref = ".testing/approvals/repository.json" },
      approval_sha256 = digest("e"),
    },
    inputs = { input() },
    browser_evidence = {
      artifact_pointer = ".testing/runs/browser/evidence.json",
      artifact_digest = digest("f"),
      approval_ref = { kind = "artifact", ref = ".testing/approvals/browser.json" },
      approval_sha256 = digest("1"),
    },
    artifact_root = ".testing/runs/testing-design",
    source_ref = { kind = "host-run", ref = "testing-design-run" },
    trace_id = "trace-testing-design",
    dedup_key = "dedup-testing-design",
  }
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

return {
  test_accepts_pointer_only_request_and_missing_requirements = function()
    local value = request()
    t.eq(contract.validate_request(value), value)
    value.inputs = {}
    value.browser_evidence = nil
    t.eq(contract.validate_request(value), value)
    local paths = contract.artifact_paths(value.artifact_root)
    t.eq(paths.repository_analysis, value.artifact_root .. "/repository-analysis.v1.json")
  end,

  test_rejects_inline_documents_credentials_raw_environment_and_unbounded_inputs = function()
    local value = request(); value.requirements_body = "inline"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.environment = { TOKEN = "secret" }
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.inputs[1].source_ref.ref = "https://example.invalid/doc?token=secret"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.repository.workspace_ref.ref = "https://user@example.invalid/worktree"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.inputs = {}
    for _ = 1, contract.max_inputs + 1 do table.insert(value.inputs, input()) end
    t.raises(function() contract.validate_request(value) end)
  end,

  test_rejects_mutable_repository_and_unsafe_artifact_pointers = function()
    local value = request(); value.repository.commit_sha = "main"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.repository.url = "https://example.invalid/testing-design.git/"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.artifact_root = ".testing/runs/../escape"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.repository.url = "git@example.invalid:testing-design.git"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.inputs[1].source_ref.ref = ".testing/inputs/requirements.md\nforged"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.browser_evidence.artifact_pointer = "/tmp/browser.json"
    t.raises(function() contract.validate_request(value) end)
    value = request(); value.trace_id = string.rep("x", 181)
    t.raises(function() contract.validate_request(value) end)
  end,

  test_context_copy_is_deep_and_digest_bound = function()
    local key = digest("2")
    local paths = contract.artifact_paths(".testing/runs/testing-design")
    local function reference(schema, pointer, char)
      return {
        schema = contract.schemas.artifact_reference,
        artifact_schema = schema,
        artifact_pointer = pointer,
        artifact_digest = digest(char),
      }
    end
    local context = {
      schema = contract.schemas.context_reference,
      analysis_key = key,
      repository_analysis = reference(contract.schemas.repository_analysis, paths.repository_analysis, "3"),
      requirements_index = reference(contract.schemas.requirements_index, paths.requirements_index, "4"),
      traceability_seed = reference(contract.schemas.traceability_seed, paths.traceability_seed, "5"),
    }
    local copied = contract.copy_context_reference(context)
    copied.repository_analysis.artifact_pointer = ".testing/runs/changed.json"
    t.eq(context.repository_analysis.artifact_pointer, paths.repository_analysis)
    local foreign = copy(context); foreign.requirements_index.artifact_schema = contract.schemas.repository_analysis
    t.raises(function() contract.validate_context_reference(foreign) end)
    local result = {
      schema = contract.schemas.result,
      status = "complete",
      replayed = false,
      analysis_key = key,
      context = context,
      source_ref = { kind = "host-run", ref = "testing-design" },
      trace_id = "trace-testing-design",
      dedup_key = "dedup-testing-design",
    }
    result.trace_id = string.rep("x", 181)
    t.raises(function() contract.validate_result(result) end)
  end,
}
