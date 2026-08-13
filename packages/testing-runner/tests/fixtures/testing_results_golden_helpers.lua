local results = require("contract.testing_results")

local digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local function ref(kind, value) return { kind = kind, ref = value } end

local case = {
  schema = results.schemas.case_result,
  case_id = "case-golden",
  repository = { id = "repo", source_ref = ref("git", "repo@commit"), source_sha256 = digest },
  reviewed_case_id = "reviewed-case-golden",
  plan_ref = ref("plan", "plans/golden"),
  plan_sha256 = digest,
  execution_mode = "browser",
  execution_status = "passed",
  classification = "deterministic",
  observations = {{ schema=results.schemas.observation, observation_id="obs-ready", kind="normalized-fact", subject="document", value="ready", source_ref=ref("runner", "observations/ready"), evidence_refs={} }},
  assertions = {
    { schema=results.schemas.assertion_result, assertion_id="assert-ready", type="document-ready", required=true, status="passed", classification="deterministic", observation_ids={"obs-ready"}, evidence_refs={} },
    { schema=results.schemas.assertion_result, assertion_id="assert-optional", type="optional-note", required=false, status="skipped", classification="not_applicable", observation_ids={}, evidence_refs={} },
  },
  evidence_refs = {},
  timing = { started_at="2026-08-13T00:00:00Z", completed_at="2026-08-13T00:00:01Z", duration_ms=1000 },
  trace_id = "trace-golden",
  dedup_key = "dedup-golden",
}

return {
  case = case,
  authority = {
    plan_ref = ref("plan", "plans/golden"),
    plan_sha256 = digest,
    reviewed_case_id = "reviewed-case-golden",
    assertions = {{ assertion_id="assert-ready", required=true }, { assertion_id="assert-optional", required=false }},
  },
  canonical_json = "{\"assertions\":[{\"assertion_id\":\"assert-ready\",\"classification\":\"deterministic\",\"evidence_refs\":[],\"observation_ids\":[\"obs-ready\"],\"required\":true,\"schema\":\"testing-assertion-result.v1\",\"status\":\"passed\",\"type\":\"document-ready\"},{\"assertion_id\":\"assert-optional\",\"classification\":\"not_applicable\",\"evidence_refs\":[],\"observation_ids\":[],\"required\":false,\"schema\":\"testing-assertion-result.v1\",\"status\":\"skipped\",\"type\":\"optional-note\"}],\"case_id\":\"case-golden\",\"classification\":\"deterministic\",\"dedup_key\":\"dedup-golden\",\"evidence_refs\":[],\"execution_mode\":\"browser\",\"execution_status\":\"passed\",\"observations\":[{\"evidence_refs\":[],\"kind\":\"normalized-fact\",\"observation_id\":\"obs-ready\",\"schema\":\"testing-observation.v1\",\"source_ref\":{\"kind\":\"runner\",\"ref\":\"observations/ready\"},\"subject\":\"document\",\"value\":\"ready\"}],\"plan_ref\":{\"kind\":\"plan\",\"ref\":\"plans/golden\"},\"plan_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"repository\":{\"id\":\"repo\",\"source_ref\":{\"kind\":\"git\",\"ref\":\"repo@commit\"},\"source_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"reviewed_case_id\":\"reviewed-case-golden\",\"schema\":\"testing-case-result.v2\",\"timing\":{\"completed_at\":\"2026-08-13T00:00:01Z\",\"duration_ms\":1000,\"started_at\":\"2026-08-13T00:00:00Z\"},\"trace_id\":\"trace-golden\"}",
  sha256 = "ad3369d83c575ab5f93f551213e8981055edfe4ecb9ca199392cb61ea16415fb",
}
