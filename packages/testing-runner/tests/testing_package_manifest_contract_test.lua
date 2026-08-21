local manifest = require("contract.testing_package_manifest")
local t = fkst.test
local sha256 = require("sha256_helpers")

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

  test_rejects_missing_content_digest = function()
    local value = valid(); value.package_content_sha256 = nil
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
}
