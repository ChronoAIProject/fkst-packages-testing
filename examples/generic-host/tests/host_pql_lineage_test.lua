local json_codec = require("testing_runtime.json")
local lineage = require("host_pql_lineage")
local support = require("host_canonical_workflow_qa_support")
local t = fkst.test

local function artifact_reference(schema, name, digest)
  return {
    schema = "testing-design.artifact-reference.v1",
    artifact_schema = schema,
    artifact_pointer = ".testing/runs/pql-lineage/design/" .. name .. ".json",
    artifact_digest = digest,
  }
end

local function context(traceability_digest)
  return {
    schema = "testing-design.context-reference.v1",
    analysis_key = string.rep("a", 64),
    repository_analysis = artifact_reference(
      "testing-design.repository-analysis.v1", "repository-analysis", string.rep("b", 64)),
    requirements_index = artifact_reference(
      "testing-design.requirements-index.v1", "requirements-index", string.rep("c", 64)),
    traceability_seed = artifact_reference(
      "testing-design.traceability-seed.v1", "traceability-seed", traceability_digest),
  }
end

local function traceability(overrides)
  local asset = {
    asset_id = "TCA-HOME-TITLE",
    asset_version = "1",
    asset_ref = { ref = "TCA-HOME-TITLE@1" },
    requirement_refs = { { ref = "REQ-HOME-TITLE" } },
  }
  for key, value in pairs(overrides or {}) do asset[key] = value end
  return json_codec.encode({ pql_lineage = { approved_assets = { asset } } }) .. "\n"
end

local function accept(bytes, context_override, decode_json)
  local digest = support.sha256_bytes(bytes)
  return lineage.accept(context_override or context(digest), {
    read_artifact_bytes = function() return bytes end,
    sha256_bytes = support.sha256_bytes,
    decode_json = decode_json or json.decode,
  })
end

local function rejected(fn)
  local ok = pcall(fn)
  t.eq(ok, false)
end

return {
  test_accepts_digest_bound_single_asset_identity = function()
    local accepted = accept(traceability())
    t.eq(accepted.asset_id, "TCA-HOME-TITLE")
    t.eq(accepted.asset_version, "1")
    t.eq(accepted.asset_ref.ref, "TCA-HOME-TITLE@1")
    t.eq(accepted.requirement_refs[1].ref, "REQ-HOME-TITLE")
    t.eq(accepted.design_case_id, "TCA-HOME-TITLE@1")
  end,

  test_rejects_digest_mismatch_before_decoding = function()
    local decoded = 0
    rejected(function()
      accept(traceability(), context(string.rep("d", 64)), function()
        decoded = decoded + 1
        return {}
      end)
    end)
    t.eq(decoded, 0)
  end,

  test_rejects_malformed_lineage_and_identity_values = function()
    for _, bytes in ipairs({
      "not-json\n",
      json_codec.encode({}) .. "\n",
      json_codec.encode({ pql_lineage = true }) .. "\n",
      json_codec.encode({ pql_lineage = { approved_assets = {} } }) .. "\n",
      json_codec.encode({ pql_lineage = { approved_assets = { {}, {} } } }) .. "\n",
      traceability({ asset_id = false }),
      traceability({ asset_id = "" }),
      traceability({ asset_version = false }),
      traceability({ asset_version = "" }),
      traceability({ asset_ref = { ref = "TCA-HOME-TITLE@2" } }),
      traceability({ requirement_refs = { { ref = "TCA-HOME-TITLE@1" } } }),
      traceability({ requirement_refs = {} }),
      traceability({ requirement_refs = { { ref = "" } } }),
    }) do
      rejected(function() accept(bytes) end)
    end
  end,

  test_rejects_invalid_context_before_reading_traceability = function()
    local value = context(string.rep("d", 64))
    value.extra = true
    local reads = 0
    rejected(function()
      lineage.accept(value, {
        read_artifact_bytes = function() reads = reads + 1; return traceability() end,
        sha256_bytes = support.sha256_bytes,
      })
    end)
    t.eq(reads, 0)
  end,
}
