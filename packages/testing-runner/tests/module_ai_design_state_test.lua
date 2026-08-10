local core = require("core")
local design_loop = require("module_ai_design_loop")
local design_state = require("module_ai_design_state")
local native = require("fkst_native")
local t = fkst.test

local run_root = ".testing/runs/inventory-reviewed"
local loop_root = run_root .. "/design-loop"
local case_ids = {
  "inventory-initial-state",
  "inventory-reserve-three",
  "inventory-state-after-reserve",
  "inventory-over-reserve-rejected",
  "inventory-state-after-rejection",
}
local subject_ids = {
  "inventory:initial-state",
  "inventory:reserve-three",
  "inventory:state-after-reserve",
  "inventory:over-reserve-rejected",
  "inventory:state-after-rejection",
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function reviewed_fixture()
  local cases = {}
  local subjects = {}
  for index, case_id in ipairs(case_ids) do
    cases[index] = {
      id = case_id,
      module_id = "inventory",
      priority = "P0",
      title = "Verify " .. case_id,
      objective = "Verify " .. case_id,
      case_kind = (index == 2 or index == 4) and "cli" or "api",
      actions = {
        { action = (index == 2 or index == 4) and "cli" or "http", target = case_id, expected = "approved" },
      },
      expected_observable = case_id .. " is observed.",
      coverage_subject_ids = { subject_ids[index] },
      provenance = { origin = "user-seed", source_pointer = loop_root .. "/seed-cases.json" },
      review_status = "executable",
    }
    subjects[index] = {
      id = subject_ids[index],
      kind = "requirement",
      priority = "P0",
      evidence_pointer = loop_root .. "/coverage-evidence-" .. tostring(index) .. ".json",
    }
  end
  local documents = {
    seed_cases = { schema = design_loop.schemas.seed_cases, cases = cases },
    deterministic_cases = { schema = design_loop.schemas.deterministic_cases, cases = {} },
    coverage_scope = { schema = design_loop.schemas.coverage_scope, subjects = subjects },
  }
  local function ref(name)
    return {
      artifact_pointer = loop_root .. "/" .. name .. ".json",
      artifact_digest = design_loop.document_digest(documents[name]),
    }
  end
  local state, artifacts = design_loop.start({
    schema = design_loop.schemas.request,
    artifact_root = loop_root,
    seed_cases_ref = ref("seed_cases"),
    deterministic_cases_ref = ref("deterministic_cases"),
    coverage_scope_ref = ref("coverage_scope"),
    max_rounds = 3,
    case_budget = 16,
    action_budget = 32,
    trace_id = "trace-inventory-reviewed",
    dedup_key = "dedup-inventory-reviewed",
  }, documents)
  t.eq(artifacts.closure.status, "reviewed-complete")
  local payload = {
    schema = "testing-runner.module-test-loop.request.v1",
    module = "inventory",
    backend = "fkst-native",
    artifact_root = run_root,
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
    ai_design_loop_state_ref = {
      artifact_pointer = state.paths.state,
      artifact_digest = design_loop.document_digest(state),
    },
  }
  local function reader(path)
    if path == state.paths.state then return native.json_encode(state) end
  end
  return payload, state, reader
end

local function expect_failure(fragment, payload, reader)
  local ok, err = pcall(design_state.load, payload, payload.artifact_root, { artifact_reader = reader })
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local function assert_case_ids(actual)
  t.eq(#actual, #case_ids)
  for index, case_id in ipairs(case_ids) do t.eq(actual[index], case_id) end
end

local function assert_loaded_state(actual, expected, state_ref)
  t.eq(actual.schema, expected.schema)
  t.eq(actual.artifact_root, expected.artifact_root)
  t.eq(actual.trace_id, expected.trace_id)
  t.eq(actual.dedup_key, expected.dedup_key)
  for _, key in ipairs({
    "coverage_matrix",
    "reviewer_findings",
    "supplementation_patch",
    "round_plan",
    "state",
    "closure",
    "residual_risk",
  }) do
    t.eq(actual.paths[key], expected.paths[key])
  end
  t.eq(actual.paths.state, state_ref.artifact_pointer)
  t.eq(design_loop.document_digest(actual), state_ref.artifact_digest)

  local closure = actual.current_artifacts.closure
  local expected_closure = expected.current_artifacts.closure
  t.eq(closure.status, expected_closure.status)
  t.eq(closure.trace_id, expected_closure.trace_id)
  t.eq(closure.dedup_key, expected_closure.dedup_key)
  t.eq(closure.round_count, expected_closure.round_count)
  t.eq(closure.final_round_digest, expected_closure.final_round_digest)
  t.eq(closure.coverage_matrix_pointer, expected_closure.coverage_matrix_pointer)
  t.eq(closure.coverage_matrix_digest, expected_closure.coverage_matrix_digest)
  t.eq(closure.unresolved_count, expected_closure.unresolved_count)
  t.eq(closure.high_priority_unresolved_count, expected_closure.high_priority_unresolved_count)

  local loaded_case_ids = {}
  for index, item in ipairs(actual.cases) do loaded_case_ids[index] = item.id end
  assert_case_ids(loaded_case_ids)
  assert_case_ids(actual.current_artifacts.round_plan.case_ids)
end

return {
  test_loads_top_level_reviewed_state_with_exact_binding = function()
    local payload, state, reader = reviewed_fixture()
    local loaded = design_state.load(payload, payload.artifact_root, { artifact_reader = reader })
    assert_loaded_state(loaded, state, payload.ai_design_loop_state_ref)
    payload.dedup_key = payload.dedup_key .. "/attempt/1"
    local replayed = design_state.load(payload, payload.artifact_root, { artifact_reader = reader })
    assert_loaded_state(replayed, state, payload.ai_design_loop_state_ref)
  end,

  test_reviewed_state_admission_fails_closed_for_invalid_artifacts = function()
    local payload, state = reviewed_fixture()
    expect_failure("artifact body is empty", payload, function() return nil end)

    local digest_payload, _, digest_reader = reviewed_fixture()
    digest_payload.ai_design_loop_state_ref.artifact_digest = "wrong-digest"
    expect_failure("testing-runner: ai-artifact-mismatch: design loop state digest", digest_payload, digest_reader)

    local unsafe_payload, _, unsafe_reader = reviewed_fixture()
    unsafe_payload.ai_design_loop_state_ref.artifact_pointer = "../state.json"
    expect_failure("ai-design-loop-malformed-reference", unsafe_payload, unsafe_reader)

    local trace_payload, trace_state = reviewed_fixture()
    trace_state.trace_id = "foreign-trace"
    trace_payload.ai_design_loop_state_ref.artifact_digest = design_loop.document_digest(trace_state)
    expect_failure("design loop identity binding", trace_payload, function() return native.json_encode(trace_state) end)

    local dedup_payload, dedup_state = reviewed_fixture()
    dedup_state.dedup_key = "foreign-dedup"
    dedup_payload.ai_design_loop_state_ref.artifact_digest = design_loop.document_digest(dedup_state)
    expect_failure("design loop identity binding", dedup_payload, function() return native.json_encode(dedup_state) end)

    local incomplete_payload, incomplete_state = reviewed_fixture()
    incomplete_state.current_artifacts.closure = nil
    incomplete_payload.ai_design_loop_state_ref.artifact_digest = design_loop.document_digest(incomplete_state)
    expect_failure("design loop closure", incomplete_payload, function() return native.json_encode(incomplete_state) end)

    local blocked_payload, blocked_state = reviewed_fixture()
    local coverage = blocked_state.current_artifacts.coverage_matrix
    local residual = {
      schema = design_loop.schemas.residual_risk,
      status = "blocked",
      round = blocked_state.round,
      unresolved = {
        { subject_id = subject_ids[1], status = "blocked", priority = "P0", rationale = "Blocked." },
      },
      unresolved_count = 1,
      high_priority_unresolved_count = 1,
      coverage_matrix_pointer = blocked_state.paths.coverage_matrix,
      coverage_matrix_digest = design_loop.document_digest(coverage),
    }
    blocked_state.current_artifacts.residual_risk = residual
    blocked_state.current_artifacts.closure.status = "blocked"
    blocked_state.current_artifacts.closure.residual_risk_pointer = blocked_state.paths.residual_risk
    blocked_state.current_artifacts.closure.residual_risk_digest = design_loop.document_digest(residual)
    blocked_payload.ai_design_loop_state_ref.artifact_digest = design_loop.document_digest(blocked_state)
    expect_failure("not reviewed-complete", blocked_payload, function() return native.json_encode(blocked_state) end)

    local foreign_payload, foreign_state = reviewed_fixture()
    foreign_state.artifact_root = ".testing/runs/foreign/design-loop"
    foreign_payload.ai_design_loop_state_ref.artifact_digest = design_loop.document_digest(foreign_state)
    expect_failure("design loop run binding", foreign_payload, function() return native.json_encode(foreign_state) end)
  end,

  test_non_cdp_native_planning_writes_five_ordered_reviewed_cases = function()
    local payload, _, reader = reviewed_fixture()
    local written = {}
    payload.dedup_key = payload.dedup_key .. "/attempt/1"
    payload.dry_run = true
    payload.preflight_result = { status = "ready" }
    payload.ui_loop = {
      base_url = "http://127.0.0.1:8080/inventory/SKU-001",
      allowed_origins = { "http://127.0.0.1:8080" },
      mutation_policy = "host-approved",
    }
    payload.module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "inventory",
          name = "Inventory",
          entry_url = payload.ui_loop.base_url,
          visible_label = "Inventory",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = run_root .. "/inventory-evidence.json",
        },
      },
    }
    payload.artifact_reader = reader
    payload.artifact_writer = function(path, body)
      written[path] = body
      return true
    end
    local result = core.run("module", payload)
    t.eq(result.status, "planned")
    local plan = json.decode(written[run_root .. "/test-plan.json"])
    local planned_case_ids = {}
    for index, item in ipairs(plan.modules[1].cases) do planned_case_ids[index] = item.id end
    assert_case_ids(planned_case_ids)
  end,

  test_nested_cdp_state_reference_fails_closed = function()
    local payload, _, reader = reviewed_fixture()
    payload.cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      ai_design_loop_state_ref = copy(payload.ai_design_loop_state_ref),
    }
    payload.ai_design_loop_state_ref = nil
    expect_failure("reviewed design fields must be top-level", payload, reader)
  end,
}
