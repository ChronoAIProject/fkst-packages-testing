local bundle_identity = require("contract.context_bundle_identity")
local convergence_identity = require("contract.convergence_identity")
local error_facts = require("contract.error_facts")
local sha256 = require("contract.sha256")
local strings = require("contract.strings")
local t = fkst.test

return {
  test_sha256_matches_fips_vectors_and_rejects_non_strings = function()
    t.eq(sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    t.eq(sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    t.eq(sha256.hex(string.rep("a", 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    t.raises(function() sha256.hex({}) end)
  end,

  test_string_compatibility_helpers_cover_boundaries = function()
    t.eq(strings.trim_end("value \t  "), "value")

    local prefix, segment = strings.split_final_path_segment("alpha/beta")
    t.eq(prefix, "alpha")
    t.eq(segment, "beta")
    t.eq(strings.split_final_path_segment("single"), nil)

    t.eq(strings.normalize_control_line(nil), nil)
    t.eq(strings.normalize_control_line(" \n\t "), nil)
    t.eq(strings.normalize_control_line(" alpha\n\tbeta "), "alpha beta")
    t.eq(strings.map_lines("a\nb\n", function(line) return "[" .. line .. "]" end), "[a]\n[b]\n[]")

    local slashed = strings.sanitize_cache_segment(" /alpha//../beta# gamma/ ", true)
    t.is_true(#slashed <= strings.max_cache_key_segment_len)
    t.eq(slashed:find("#", 1, true), nil)

    local flattened = strings.sanitize_cache_segment("--alpha/beta--", false)
    t.eq(flattened, "alpha-beta")
    t.eq(strings.sanitize_cache_segment("###", false), "empty")
    t.eq(#strings.sanitize_cache_segment(string.rep("x", 150), true), strings.max_cache_key_segment_len)
  end,

  test_context_bundle_identity_round_trips_and_bounds_segments = function()
    local prefix = bundle_identity.bundle_cache_prefix
    local identity = bundle_identity.from_values("owner/repo#issue/42", "version 1", prefix)
    t.is_true(#identity.key <= bundle_identity.max_cache_key_len)

    local parsed = bundle_identity.from_key(identity.key, prefix)
    t.eq(parsed.key, identity.key)
    t.eq(parsed.proposal_key_segment, identity.proposal_key_segment)
    t.eq(parsed.version_key_segment, identity.version_key_segment)

    local bounded = bundle_identity.from_values(
      string.rep("owner/repository/", 20),
      string.rep("version", 20),
      prefix
    )
    t.is_true(#bounded.key <= bundle_identity.max_cache_key_len)
    t.is_true(#bounded.version_key_segment <= bundle_identity.max_version_segment_len)

    local long_key = prefix .. string.rep("p", 150) .. "/" .. string.rep("v", 130)
    local long_identity = bundle_identity.from_key(long_key, prefix)
    t.is_true(#long_identity.proposal_directory_segment <= bundle_identity.max_directory_segment_len)
    t.is_true(#long_identity.version_directory_segment <= bundle_identity.max_directory_segment_len)

    local fallback = bundle_identity.from_values("   ", "###", prefix)
    t.eq(fallback.proposal_key_segment, "proposal")
    t.eq(fallback.version_key_segment, "version")
    local directory_fallback = bundle_identity.from_key(prefix .. "---/---", prefix)
    t.eq(directory_fallback.proposal_directory_segment, "proposal")
    t.eq(directory_fallback.version_directory_segment, "version")

    t.eq(bundle_identity.from_key("wrong-prefix/value", prefix), nil)
    t.eq(bundle_identity.from_key(prefix .. "missing-version", prefix), nil)
    t.eq(bundle_identity.from_key(prefix .. "/version", prefix), nil)
  end,

  test_error_and_convergence_compatibility_edges = function()
    local message = "contract.testing-package-manifest: unsafe-reference: invalid package path"
    t.eq(error_facts.error_class_from_message(message), "unsafe-reference")
    t.eq(
      error_facts.error_message("Invalid Subsystem!", "unsafe-reference", "bad"),
      "contract.error-facts: invalid-subsystem: bad"
    )

    local identity = convergence_identity.from_parts(
      "reviewer",
      "proposal-1",
      "dedup-1",
      { angle_lane = "fidelity" }
    )
    t.eq(identity.generation, 0)
    t.eq(identity.round, 0)
  end,
}
