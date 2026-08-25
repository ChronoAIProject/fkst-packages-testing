local results = require("contract.testing_results")
local manifest_contract = require("contract.testing_evidence_manifest")
local golden = require("tests.fixtures.testing_results_golden_helpers")
local real_sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test
local digest = string.rep("a", 64)
local persisted_digest = string.rep("b", 64)
local observation_fixture_root = "packages/testing-runner/tests/fixtures/testing-observation.v1"
local invalid_observation_fixtures = {
  "invalid-control-character",
  "invalid-empty-kind",
  "invalid-empty-observation-id",
  "invalid-empty-reference-ref",
  "invalid-empty-value",
  "invalid-evidence-refs-object",
  "invalid-malformed-evidence-reference",
  "invalid-malformed-source-reference",
  "invalid-missing-required-field",
  "invalid-multibyte-over-byte-limit",
  "invalid-non-hex-digest",
  "invalid-overlong-kind",
  "invalid-overlong-observation-id",
  "invalid-overlong-reference-kind",
  "invalid-overlong-reference-ref",
  "invalid-overlong-value",
  "invalid-short-digest",
  "invalid-too-many-evidence-references",
  "invalid-unknown-evidence-reference-field",
  "invalid-unknown-source-reference-field",
  "invalid-unknown-top-level-field",
  "invalid-unsupported-schema-major",
  "invalid-unsupported-schema-name",
  "invalid-uppercase-digest",
}

local function ref(kind, value) return { kind = kind, ref = value } end
local function observation_fixture(name)
  local handle = assert(io.open(observation_fixture_root .. "/" .. name .. ".json", "rb"))
  local body = handle:read("*a")
  handle:close()
  return json.decode(body)
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end
local function assertion(assertion_id, required, status)
  return { schema=results.schemas.assertion_result, assertion_id=assertion_id, type="document-ready", required=required, status=status, classification=(status == "passed" and "deterministic" or status == "failed" and "assertion_failure" or "skipped"), observation_ids=(status == "skipped" and {} or {"obs-1"}), evidence_refs={} }
end
local function authority(assertions)
  local planned = {}
  for _, item in ipairs(assertions or {{"assert-1", true}}) do table.insert(planned, { assertion_id=item[1], required=item[2] }) end
  return { plan_ref=ref("plan", "plans/1"), plan_sha256=digest, reviewed_case_id="reviewed-case-1", assertions=planned }
end
local function make_case(status, classification, assertions)
  return {
    schema=results.schemas.case_result, case_id="case-1", repository={id="repo", source_ref=ref("git", "repo@commit"), source_sha256=digest}, reviewed_case_id="reviewed-case-1", plan_ref=ref("plan", "plans/1"), plan_sha256=digest,
    execution_mode="cli", execution_status=status, classification=classification,
    observations={{schema=results.schemas.observation, observation_id="obs-1", kind="normalized-fact", subject="document", value="ready", source_ref=ref("runner", "observations/1"), evidence_refs={}}}, assertions=assertions or {}, evidence_refs={},
    timing={started_at="2026-08-13T00:00:00Z", completed_at="2026-08-13T00:00:01Z", duration_ms=1000}, trace_id="trace-1", dedup_key="dedup-1",
  }
end
local function valid_case(status)
  if status == "passed" then return make_case(status, "deterministic", {assertion("assert-1", true, "passed")}) end
  if status == "failed" then return make_case(status, "assertion_failure", {assertion("assert-1", true, "failed")}) end
  if status == "skipped" then local value=make_case(status, "skipped", {assertion("assert-1", true, "skipped")}); value.non_execution_reason="case-not-selected"; return value end
  if status == "error" then local value=make_case(status, "execution_error", {assertion("assert-1", true, "skipped")}); value.error={code="provider-timeout",message="execution ended before assertions completed"}; return value end
  local value=make_case(status, status, {assertion("assert-1", true, "skipped")}); value.non_execution_reason=(status == "blocked" and "precondition-unavailable" or "runner-disconnected"); return value
end
local function evidence_manifest(case)
  local manifest = {
    schema=manifest_contract.schema, manifest_id="manifest-1", canonicalization=manifest_contract.canonicalization,
    canonical_sha256=digest, repository=case.repository, run_id="run-1", plan_ref=case.plan_ref, plan_sha256=case.plan_sha256,
    entries={
      {evidence_id="evidence-log", case_id=case.case_id, assertion_id="assert-1", role="runner-log", artifact_ref=ref("artifact", ".testing/runs/run-1/evidence/runner.log"), sha256=digest, media_type="text/plain", size_bytes=12, producer="testing-runner", producer_version="1.0.0", created_at="2026-08-13T00:00:01Z", sensitivity="public", redaction_classification="none", policy_version="evidence-policy-v1", policy_status="approved", provenance={source_kind="runner", source_ref="runner/execution", source_sha256=digest}},
      {evidence_id="evidence-shot", case_id=case.case_id, role="screenshot", artifact_ref=ref("artifact", ".testing/runs/run-1/evidence/screenshot.png"), sha256=digest, media_type="image/png", size_bytes=24, producer="browser-runner", producer_version="1.0.0", created_at="2026-08-13T00:00:01Z", sensitivity="internal", redaction_classification="none", policy_version="evidence-policy-v1", policy_status="approved", provenance={source_kind="browser", source_ref="browser/execution", source_sha256=digest}},
      {evidence_id="evidence-json", case_id=case.case_id, role="sanitized-json", artifact_ref=ref("artifact", ".testing/runs/run-1/evidence/result.json"), sha256=digest, media_type="application/json", size_bytes=18, producer="testing-runner", producer_version="1.0.0", created_at="2026-08-13T00:00:01Z", sensitivity="public", redaction_classification="sanitized", policy_version="evidence-policy-v1", policy_status="redacted", provenance={source_kind="runner", source_ref="runner/sanitized-result", source_sha256=digest}},
    },
  }
  manifest.canonical_sha256=real_sha256(manifest_contract.canonicalize(manifest))
  return manifest
end

local function result_set(case, manifest)
  return {schema=results.schemas.case_result_set,set_id="set-1",run_id="run-1",plan_ref=case.plan_ref,plan_sha256=case.plan_sha256,cases={case},evidence_manifest_ref={kind="artifact",ref=".testing/runs/run-1/evidence-manifest.json",sha256=persisted_digest},evidence_manifest_sha256=manifest.canonical_sha256,evidence_manifest_artifact_sha256=persisted_digest,trace_id=case.trace_id,dedup_key=case.dedup_key}
end

return {
  test_observation_shared_schema_fixtures_match_portable_validation = function()
    for _, name in ipairs({"valid-with-digests", "valid-without-digests"}) do
      local value = observation_fixture(name)
      t.eq(results.validate_observation(value), value)
    end
    for _, name in ipairs(invalid_observation_fixtures) do
      t.raises(function() results.validate_observation(observation_fixture(name)) end)
    end
  end,
  test_validates_cli_http_browser = function()
    for _, mode in ipairs({"cli", "http", "browser"}) do local value=valid_case("passed"); value.execution_mode=mode; t.eq(results.validate_case_result(value, authority()), value) end
  end,
  test_accepts_complete_execution_outcome_matrix = function()
    for _, status in ipairs({"passed", "failed", "skipped", "error", "blocked", "lost"}) do local value=valid_case(status); t.eq(results.validate_case_result(value, authority()), value) end
    local not_applicable=valid_case("skipped"); not_applicable.classification="not_applicable"; not_applicable.assertions[1].classification="not_applicable"; t.eq(results.validate_case_result(not_applicable, authority()), not_applicable)
  end,
  test_rejects_plan_assertion_omission_foreign_identity_and_requiredness = function()
    local value=valid_case("passed"); table.insert(value.assertions, assertion("assert-optional", false, "skipped")); local plan=authority({{"assert-1",true},{"assert-optional",false}}); t.eq(results.validate_case_result(value, plan), value)
    local reordered=copy(value); reordered.assertions[1],reordered.assertions[2]=reordered.assertions[2],reordered.assertions[1]; t.raises(function() results.validate_case_result(reordered, plan) end)
    local omitted=copy(value); table.remove(omitted.assertions, 1); t.raises(function() results.validate_case_result(omitted, plan) end)
    local foreign=copy(value); foreign.assertions[2].assertion_id="assert-foreign"; t.raises(function() results.validate_case_result(foreign, plan) end)
    local weakened=copy(value); weakened.assertions[1].required=false; weakened.assertions[1].status="skipped"; weakened.assertions[1].classification="skipped"; t.raises(function() results.validate_case_result(weakened, plan) end)
    local duplicate=copy(value); table.insert(duplicate.assertions, copy(duplicate.assertions[1])); t.raises(function() results.validate_case_result(duplicate, plan) end)
  end,
  test_rejects_every_contradictory_outcome_dimension = function()
    local mutations = {
      function(value) value.classification="blocked" end,
      function(value) value.assertions[1].status="failed"; value.assertions[1].classification="assertion_failure" end,
      function(value) value.error={code="unexpected",message="not allowed"} end,
      function(value) value.non_execution_reason="unexpected" end,
    }
    for _, mutate in ipairs(mutations) do local value=valid_case("passed"); mutate(value); t.raises(function() results.validate_case_result(value, authority()) end) end
    local failed=valid_case("failed"); failed.assertions[1].status="passed"; failed.assertions[1].classification="deterministic"; t.raises(function() results.validate_case_result(failed, authority()) end)
    local skipped=valid_case("skipped"); skipped.assertions[1].status="failed"; skipped.assertions[1].classification="assertion_failure"; t.raises(function() results.validate_case_result(skipped, authority()) end); skipped=valid_case("skipped"); skipped.non_execution_reason=nil; t.raises(function() results.validate_case_result(skipped, authority()) end)
    for _, status in ipairs({"error","blocked","lost"}) do local value=valid_case(status); value.assertions[1].status="failed"; value.assertions[1].classification="assertion_failure"; t.raises(function() results.validate_case_result(value, authority()) end) end
    local errored=valid_case("error"); errored.error=nil; t.raises(function() results.validate_case_result(errored, authority()) end)
    for _, status in ipairs({"blocked","lost"}) do local value=valid_case(status); value.non_execution_reason=nil; t.raises(function() results.validate_case_result(value, authority()) end) end
  end,
  test_derives_cli_http_and_browser_plan_assertion_authorities = function()
    local plan_ref=ref("plan","plans/1")
    local fixed=results.plan_assertion_authorities({cases={{case_id="fixed",kind="cli",assertions={{type="exit-code"}}}}},plan_ref,digest)
    t.eq(fixed[1].assertions[1].assertion_id,"assertion-1"); t.eq(fixed[1].assertions[1].required,true)
    local browser=results.plan_assertion_authorities({cases={{case_id="browser",kind="browser",completion_assertions={{assertion_id="callback-observed",required=true},{assertion_id="optional-status",required=false}}}}},plan_ref,digest)
    t.eq(browser[1].assertions[1].assertion_id,"callback-observed"); t.eq(browser[1].assertions[1].required,true)
    t.eq(browser[1].assertions[2].assertion_id,"optional-status"); t.eq(browser[1].assertions[2].required,false)
  end,

  test_validates_set_and_plan_authorities = function()
    local case=valid_case("passed"); case.evidence_refs={{kind="evidence",ref="evidence-log"}}; case.assertions[1].evidence_refs={{kind="evidence",ref="evidence-log"}}
    local manifest=evidence_manifest(case); local value=result_set(case, manifest)
    t.eq(results.validate_case_result_set(value, {authority()}, manifest), value)
    local no_persisted_digest=copy(value); no_persisted_digest.evidence_manifest_artifact_sha256=nil; no_persisted_digest.evidence_manifest_ref.sha256=nil
    t.eq(results.validate_case_result_set(no_persisted_digest, {authority()}, manifest), no_persisted_digest)
    local mismatched=copy(value); mismatched.evidence_manifest_ref.sha256=string.rep("c",64)
    t.raises(function() results.validate_case_result_set(mismatched, {authority()}, manifest) end)
    t.raises(function() results.validate_case_result_set(copy(value), {}, manifest) end)
    local foreign=authority(); foreign.plan_ref=ref("plan","foreign"); t.raises(function() results.validate_case_result_set(value, {foreign}, manifest) end)
  end,
  test_rejects_manifest_integrity_and_reference_failures = function()
    local case=valid_case("passed"); case.evidence_refs={{kind="evidence",ref="evidence-log"}}; case.assertions[1].evidence_refs={{kind="evidence",ref="evidence-log"}}
    local manifest=evidence_manifest(case); local set=result_set(case, manifest)
    local bad=copy(manifest); bad.entries[1].evidence_id="evidence-duplicate"; table.insert(bad.entries, copy(bad.entries[1])); t.raises(function() results.validate_case_result_set(set, nil, bad) end)
    bad=copy(manifest); bad.entries[1].case_id="foreign-case"; t.raises(function() results.validate_case_result_set(set, nil, bad) end)
    bad=copy(manifest); bad.entries[1].role="unsupported"; t.raises(function() results.validate_case_result_set(set, nil, bad) end)
    bad=copy(manifest); bad.entries[1].media_type="application/json"; t.raises(function() results.validate_case_result_set(set, nil, bad) end)
    bad=copy(manifest); bad.entries[1].artifact_ref=ref("artifact", ".testing/runs/foreign-run/evidence/runner.log"); t.raises(function() results.validate_case_result_set(set, nil, bad) end)
    local missing=copy(set); missing.cases[1].evidence_refs={{kind="evidence",ref="missing"}}; t.raises(function() results.validate_case_result_set(missing, nil, manifest) end)
    local cross=valid_case("passed"); table.insert(cross.assertions, assertion("assert-2", true, "passed"))
    cross.evidence_refs={{kind="evidence",ref="evidence-log"}}
    cross.assertions[1].evidence_refs={{kind="evidence",ref="evidence-shot"}}
    local cross_manifest=evidence_manifest(cross); cross_manifest.entries[2].assertion_id="assert-2"
    local cross_set=result_set(cross, cross_manifest)
    t.raises(function() results.validate_case_result_set(cross_set, {authority({{"assert-1",true},{"assert-2",true}})}, cross_manifest) end)
  end,
  test_manifest_digest_is_deterministic = function()
    local case=valid_case("passed"); case.evidence_refs={{kind="evidence",ref="evidence-log"}}; case.assertions[1].evidence_refs={{kind="evidence",ref="evidence-log"}}
    local manifest=evidence_manifest(case); local reordered=copy(manifest); reordered.entries[1]=copy(manifest.entries[1]); t.eq(manifest_contract.canonicalize(manifest), manifest_contract.canonicalize(reordered)); t.eq(manifest_contract.sha256(manifest, real_sha256), manifest.canonical_sha256)
    local foreign_case=copy(case); foreign_case.case_id="foreign-case"; local foreign_set=result_set(foreign_case, manifest); t.raises(function() manifest_contract.validate(manifest, foreign_set) end)
  end,
  test_matches_independent_golden_bytes_and_sha256 = function()
    local canonical=results.canonicalize(golden.case); t.eq(canonical, golden.canonical_json); t.eq(real_sha256(canonical), golden.sha256); t.eq(results.sha256(golden.case, real_sha256), golden.sha256)
    local changed=copy(golden.case); changed.trace_id="trace-golden-changed"; local changed_bytes=results.canonicalize(changed); t.eq(changed_bytes == golden.canonical_json, false); t.eq(real_sha256(changed_bytes) == golden.sha256, false)
  end,
  test_rejects_unknown_fields_bad_digest_duplicates_foreign_plan_and_unsupported_major = function()
    local value=valid_case("passed"); value.extra=true; t.raises(function() results.validate_case_result(value, authority()) end)
    value=valid_case("passed"); value.plan_sha256="bad"; t.raises(function() results.validate_case_result(value, authority()) end)
    local duplicate_case=valid_case("passed"); duplicate_case.evidence_refs={{kind="evidence",ref="evidence-log"}}; duplicate_case.assertions[1].evidence_refs={{kind="evidence",ref="evidence-log"}}
    local duplicate_manifest=evidence_manifest(duplicate_case); local set=result_set(duplicate_case, duplicate_manifest); set.cases={duplicate_case,copy(duplicate_case)}; t.raises(function() results.validate_case_result_set(set, nil, duplicate_manifest) end)
    set.cases={duplicate_case}; set.cases[1].plan_ref=ref("plan","foreign"); t.raises(function() results.validate_case_result_set(set, nil, duplicate_manifest) end)
    t.raises(function() results.negotiate("testing-case-result.v9",{[2]=true}) end); t.eq(results.negotiate(results.schemas.case_result,{[2]=true}),2)
  end,
}
