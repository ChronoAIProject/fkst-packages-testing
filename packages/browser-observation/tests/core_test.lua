local core = require("core")
local t = fkst.test

local function observation(overrides)
  local item = {
    id = "observed-rootdocs",
    name = "Docs",
    entry_url = "http://localhost:3000/docs",
    route = "/docs",
    visible_label = "Docs",
    discovery_source = "nav-link",
    confidence = "medium",
    evidence_pointer = ".testing/runs/browser-observation/evidence/discovery/observed-rootdocs.json",
  }
  for key, value in pairs(overrides or {}) do item[key] = value end
  return item
end

local function manifest(overrides)
  local payload = {
    schema = core.manifest_schema,
    base_url = "http://localhost:3000",
    artifact_root = ".testing/runs/browser-observation",
    observation_count = 1,
    observations = { observation() },
  }
  for key, value in pairs(overrides or {}) do payload[key] = value end
  return payload
end

return {
  test_valid_manifest_accepts_discovery_observations = function()
    local payload = core.validate_manifest(manifest())
    t.eq(payload.schema, "browser-observation.observations.v1")
    t.eq(payload.observations[1].discovery_source, "nav-link")
    t.eq(payload.observations[1].confidence, "medium")
  end,

  test_local_only_urls_are_required = function()
    t.raises(function()
      core.validate_manifest(manifest({ base_url = "https://example.com" }))
    end)
    t.raises(function()
      core.validate_manifest(manifest({ base_url = "https://localhost:3000" }))
    end)
    t.raises(function()
      core.validate_manifest(manifest({ observations = { observation({ entry_url = "https://example.com/docs" }) } }))
    end)
    t.raises(function()
      core.validate_manifest(manifest({ observations = { observation({ entry_url = "https://localhost:3000/docs" }) } }))
    end)
  end,

  test_clean_routes_and_pointer_artifacts_are_required = function()
    t.raises(function()
      core.validate_manifest(manifest({ observations = { observation({ route = "/docs?x=1#top" }) } }))
    end)
    t.raises(function()
      core.validate_manifest(manifest({ artifact_root = "tmp/browser-observation" }))
    end)
    t.raises(function()
      core.validate_manifest(manifest({ observations = { observation({ evidence_pointer = ".testing/runs/other/evidence/doc.json" }) } }))
    end)
  end,

  test_unknown_inline_payload_fields_are_rejected = function()
    t.raises(function()
      core.validate_manifest(manifest({ extra = true }))
    end)
    local item = observation({ screenshot = "inline-state" })
    t.raises(function()
      core.validate_manifest(manifest({ observations = { item } }))
    end)
  end,

  test_forbidden_payload_terms_are_rejected = function()
    for _, field in ipairs({ "name", "visible_label", "evidence_pointer" }) do
      local item = observation({ [field] = "token" })
      t.raises(function()
        core.validate_manifest(manifest({ observations = { item } }))
      end)
    end
  end,

  test_observation_count_matches_dense_list = function()
    t.raises(function()
      core.validate_manifest(manifest({ observation_count = 2 }))
    end)
    t.raises(function()
      core.validate_manifest(manifest({ observations = { [2] = observation() }, observation_count = 1 }))
    end)
  end,

  test_limit_observations_truncates_deterministically = function()
    local selected = core.limit_observations({ observation({ id = "one" }), observation({ id = "two" }) }, 1)
    t.eq(#selected, 1)
    t.eq(selected[1].id, "one")
  end,

  test_result_blocks_until_observation_file_exists = function()
    local payload = {
      schema = "browser-observation.observe.v1",
      base_url = "http://localhost:3000",
      artifact_root = ".testing/runs/browser-observation",
    }
    local result = core.result(payload)
    t.eq(result.schema, "browser-observation.result.v1")
    t.eq(result.status, "blocked")
    t.eq(result.observation_path, ".testing/runs/browser-observation/observer/observations.json")
    core.validate_result(result)
  end,

  test_result_passes_when_observation_manifest_is_present = function()
    local payload = {
      schema = "browser-observation.observe.v1",
      base_url = "http://127.0.0.1:3000",
      artifact_root = ".testing/runs/browser-observation",
      observation_path = ".testing/runs/browser-observation/custom/observations.json",
    }
    local result = core.result(payload, function(path)
      t.eq(path, ".testing/runs/browser-observation/custom/observations.json")
      return '{"schema":"browser-observation.observations.v1","observation_count":2,"observations":[]}'
    end)
    t.eq(result.status, "passed")
    t.eq(result.observation_count, 2)
    core.validate_result(result)
  end,

  test_result_rejects_non_local_and_out_of_root_paths = function()
    t.raises(function()
      core.result({ schema = "browser-observation.observe.v1", base_url = "https://example.com", artifact_root = ".testing/runs/browser-observation" })
    end)
    t.raises(function()
      core.result({
        schema = "browser-observation.observe.v1",
        base_url = "http://localhost:3000",
        artifact_root = ".testing/runs/browser-observation",
        observation_path = ".testing/runs/other/observations.json",
      })
    end)
  end,
}
