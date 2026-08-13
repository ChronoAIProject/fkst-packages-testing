local results = require("contract.testing_results")
local golden = require("tests.fixtures.testing_results_golden_helpers")
local t = fkst.test
local digest = string.rep("a", 64)

local function ref(kind, value) return { kind = kind, ref = value } end
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
local function real_sha256(bytes)
  local input, output = os.tmpname(), os.tmpname()
  local handle = assert(io.open(input, "wb")); handle:write(bytes); handle:close()
  local ok, _, code = os.execute("sha256sum " .. input .. " > " .. output)
  local digest_file = assert(io.open(output, "r")); local computed = assert(digest_file:read("*l")):match("^([0-9a-f]+)"); digest_file:close()
  os.remove(input); os.remove(output)
  if not (ok == true or ok == 0) then error("sha256sum failed exit=" .. tostring(code)) end
  return computed
end

return {
  test_validates_cli_http_browser = function()
    for _, mode in ipairs({"cli", "http", "browser"}) do local value=valid_case("passed"); value.execution_mode=mode; t.eq(results.validate_case_result(value, authority()), value) end
  end,
  test_accepts_complete_execution_outcome_matrix = function()
    for _, status in ipairs({"passed", "failed", "skipped", "error", "blocked", "lost"}) do local value=valid_case(status); t.eq(results.validate_case_result(value, authority()), value) end
    local not_applicable=valid_case("skipped"); not_applicable.classification="not_applicable"; not_applicable.assertions[1].classification="not_applicable"; t.eq(results.validate_case_result(not_applicable, authority()), not_applicable)
  end,
  test_rejects_plan_assertion_omission_foreign_identity_and_requiredness = function()
    local value=valid_case("passed"); table.insert(value.assertions, assertion("assert-optional", false, "skipped")); local plan=authority({{"assert-1",true},{"assert-optional",false}}); t.eq(results.validate_case_result(value, plan), value)
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
  test_validates_set_and_plan_authorities = function()
    local value={schema=results.schemas.case_result_set,set_id="set-1",plan_ref=ref("plan","plans/1"),plan_sha256=digest,cases={valid_case("passed")},trace_id="trace-set",dedup_key="dedup-set"}
    t.eq(results.validate_case_result_set(value, {authority()}), value)
    t.raises(function() results.validate_case_result_set(copy(value), {}) end)
    local foreign=authority(); foreign.plan_ref=ref("plan","foreign"); t.raises(function() results.validate_case_result_set(value, {foreign}) end)
  end,
  test_matches_independent_golden_bytes_and_sha256 = function()
    local canonical=results.canonicalize(golden.case); t.eq(canonical, golden.canonical_json); t.eq(real_sha256(canonical), golden.sha256); t.eq(results.sha256(golden.case, real_sha256), golden.sha256)
    local changed=copy(golden.case); changed.trace_id="trace-golden-changed"; local changed_bytes=results.canonicalize(changed); t.eq(changed_bytes == golden.canonical_json, false); t.eq(real_sha256(changed_bytes) == golden.sha256, false)
  end,
  test_rejects_unknown_fields_bad_digest_duplicates_foreign_plan_and_unsupported_major = function()
    local value=valid_case("passed"); value.extra=true; t.raises(function() results.validate_case_result(value, authority()) end)
    value=valid_case("passed"); value.plan_sha256="bad"; t.raises(function() results.validate_case_result(value, authority()) end)
    local set={schema=results.schemas.case_result_set,set_id="set",plan_ref=ref("plan","plans/1"),plan_sha256=digest,cases={valid_case("passed"),valid_case("passed")},trace_id="trace",dedup_key="dedup"}; t.raises(function() results.validate_case_result_set(set) end)
    set.cases={valid_case("passed")}; set.cases[1].plan_ref=ref("plan","foreign"); t.raises(function() results.validate_case_result_set(set) end)
    t.raises(function() results.negotiate("testing-case-result.v9",{[2]=true}) end); t.eq(results.negotiate(results.schemas.case_result,{[2]=true}),2)
  end,
}
