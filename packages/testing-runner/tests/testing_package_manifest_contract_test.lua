local manifest = require("contract.testing_package_manifest")
local canonical_json = require("contract.canonical_json")
local t = fkst.test
local sha256 = require("tests.fixtures.sha256_helpers")

local function digest(char) return string.rep(char, 64) end

local function valid()
  return {
    schema = manifest.schema,
    canonicalization = manifest.canonicalization,
    package_id = "testing-runner",
    package_version = "1.0.0",
    source_commit = string.rep("a", 40),
    package_content_sha256 = digest("b"),
    supported_contracts = {
      majors = { "testing-runner.v1" },
      canonicalization_profiles = { manifest.canonicalization },
    },
    entrypoints = {
      { name = "testing-runner.run", contract_major = "testing-runner.v1", capabilities = { "semantic-runner" } },
    },
    semantic_capabilities = { "semantic-runner" },
    runtime_requirements = { lua = "5.4.0", platforms = { "linux-amd64" } },
    dependencies = {
      fkst_packages = { id = "fkst-packages", commit = string.rep("c", 40) },
      fkst_substrate = { id = "fkst-substrate", commit = string.rep("d", 40) },
    },
    producer = { name = "fkst-packages-testing", version = "1.0.0", toolchain = "python-3.11" },
    creation_metadata = { created_at = "2026-08-21T00:00:00Z", build_id = "fixture-build" },
    manifest_digest = digest("e"),
  }
end

local function without_digest(value)
  local copy = {}
  for key, item in pairs(value) do if key ~= "manifest_digest" then copy[key] = item end end
  return copy
end

return {
  test_accepts_valid_manifest_and_expected_identity = function()
    local value = valid()
    t.eq(manifest.validate(value, {
      package_id = "testing-runner",
      package_version = "1.0.0",
      source_commit = string.rep("a", 40),
      package_content_sha256 = digest("b"),
      entrypoint = "testing-runner.run",
      contract_major = "testing-runner.v1",
      capability = "semantic-runner",
    }), value)
  end,

  test_rejects_missing_malformed_and_non_lowercase_digests = function()
    local value = valid(); value.package_content_sha256 = nil
    t.raises(function() manifest.validate(value) end)
    value = valid(); value.package_id = ""
    t.raises(function() manifest.validate(value) end)
    value = valid(); value.package_content_sha256 = "not-a-digest"
    t.raises(function() manifest.validate(value) end)
    value = valid(); value.package_content_sha256 = string.rep("A", 64)
    t.raises(function() manifest.validate(value) end)
  end,

  test_rejects_floating_dependency_and_source_refs = function()
    local value = valid(); value.source_commit = "main"
    t.raises(function() manifest.validate(value) end)
    value = valid(); value.dependencies.fkst_packages.commit = "workspace"
    t.raises(function() manifest.validate(value) end)
  end,

  test_rejects_identity_digest_and_version_mismatches = function()
    local value = valid()
    t.raises(function() manifest.validate(value, { package_content_sha256 = digest("f") }) end)
    value = valid(); value.package_version = "1.0"
    t.raises(function() manifest.validate(value) end)
  end,

  test_rejects_unsupported_major_and_unknown_entrypoint = function()
    local value = valid(); value.entrypoints[1].contract_major = "testing-runner.v2"
    t.raises(function() manifest.validate(value) end)
    value = valid(); value.entrypoints[1].name = "testing-runner.unknown"
    t.raises(function() manifest.validate(value) end)
  end,

  test_rejects_capability_mismatch = function()
    local value = valid(); value.entrypoints[1].capabilities = { "undeclared" }
    t.raises(function() manifest.validate(value) end)
  end,

  test_rejects_manifest_digest_mismatch = function()
    local value = valid()
    t.raises(function() manifest.validate(value, nil, sha256) end)
  end,

  test_canonicalization_is_stable = function()
    local value = valid()
    local reordered = valid()
    reordered.semantic_capabilities = { "semantic-runner" }
    t.eq(manifest.canonicalize(value), manifest.canonicalize(reordered))
  end,

  test_validation_matches_cross_language_manifest_digest = function()
    local value = valid()
    value.manifest_digest = "905948ed62d0fd3f13d5cf0f77dbfc85cba8376e1b97bdc1f836a3514f6dfc4f"
    t.eq(sha256(manifest.canonicalize(without_digest(value))), value.manifest_digest)
    t.eq(manifest.validate(value, nil, sha256), value)
  end,

  test_canonicalization_matches_cross_language_known_answer = function()
    local value = {
      array = { "first", "雪" },
      backslash = "C:\\tmp\\file",
      control = "\b\f\n\r\t\0\31",
      empty_array = canonical_json.array({}),
      empty_object = canonical_json.object({}),
      integer_max = canonical_json.max_integer,
      integer_min = canonical_json.min_integer,
      nested = { quote = '"', ["β"] = "unicode" },
      unicode = "雪😀",
      [""] = "bmp-private-use",
      ["😀"] = "supplementary",
    }
    local expected = '{"array":["first","雪"],"backslash":"C:\\\\tmp\\\\file","control":"\\b\\f\\n\\r\\t\\u0000\\u001f","empty_array":[],"empty_object":{},"integer_max":9007199254740991,"integer_min":-9007199254740991,"nested":{"quote":"\\\"","β":"unicode"},"unicode":"雪😀","":"bmp-private-use","😀":"supplementary"}'
    local canonical = manifest.canonicalize(value)
    t.eq(canonical, expected)
    t.eq(sha256(canonical), "2211744d7633cbdc2adbc647b1601e162b5269fba7800fa1c446e8d1a8cc9a87")
  end,

  test_canonicalization_rejects_ambiguous_or_unsafe_values = function()
    t.raises(function() canonical_json.encode(1.5) end)
    t.raises(function() canonical_json.encode(canonical_json.max_integer + 1) end)
    t.raises(function() canonical_json.encode({ [2] = "gap" }) end)
    t.raises(function() canonical_json.encode({ [1] = "array", key = "object" }) end)
    t.raises(function() canonical_json.encode(string.char(0xff)) end)
    local cyclic = {}; cyclic[1] = cyclic
    t.raises(function() canonical_json.encode(cyclic) end)
  end,

  test_canonicalization_supports_null_and_explicit_empty_containers = function()
    t.eq(canonical_json.encode({ canonical_json.null }), "[null]")
    t.eq(canonical_json.encode({}), "[]")
    t.eq(canonical_json.encode(canonical_json.array({})), "[]")
    t.eq(canonical_json.encode(canonical_json.object({})), "{}")
  end,
}
