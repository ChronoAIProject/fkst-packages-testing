local core = require("core")
local analyzer = require("code_analysis.analyzer")
local code_analysis = require("code_analysis.artifact")
local runtime_digest = require("testing_runtime.digest")
local t = fkst.test

local fixture_source = [=[-- function hidden_line_comment()
--[[ function hidden_block_comment() ]]
local quoted = "function hidden_string() end\\\""
local long_text = [==[function hidden_long_string() end]==]
local function calculate_total(left, right)
  return left + right
end
function Calculator.compute(value)
  return value
end
return calculate_total
]=]

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_file(path, body)
  local directory = assert(path:match("^(.*)/[^/]+$"))
  assert(os.execute("mkdir -p " .. shell_quote(directory)))
  local handle = assert(io.open(path, "wb"))
  assert(handle:write(body))
  handle:close()
  return true
end

local function assert_error_contains(fn, expected)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(expected, 1, true) ~= nil)
end

local function prepare_fixture(root)
  write_file(root .. "/src/calculator.lua", fixture_source)
  return root
end

local function sha256_file(path)
  local command = "node libraries/testing_runtime/bin/fkst-testing-runtime.js hash-file --input " .. shell_quote(path)
  local handle = assert(io.popen(command))
  local value = assert(handle:read("*a")):match("^([0-9a-f]+)%s*$")
  assert(handle:close())
  return value
end

local function read_sha256_file(path)
  local command = "node libraries/testing_runtime/bin/fkst-testing-runtime.js read-hashed-file --input " .. shell_quote(path)
  local handle = assert(io.popen(command))
  local output = assert(handle:read("*a"))
  assert(handle:close())
  t.eq(output:sub(65, 65), "\n")
  return output:sub(66), output:sub(1, 64)
end

local function scope(overrides)
  local payload = {
    schema = core.scope_schema,
    base_url = "http://localhost:8080/app?drop=yes#frag",
    allowed_origins = { "http://localhost:8080" },
    sessions = {
      { role = "base", browser_harness_command = "true" },
      { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
    },
    observations = {
      {
        id = "dashboard-route",
        name = "Dashboard",
        entry_url = "http://localhost:8080/app/dashboard?view=private#state",
        visible_label = "Dashboard",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/discovery/evidence/dashboard",
      },
      {
        id = "dashboard-browser-visible",
        name = "Dashboard action",
        entry_url = "http://localhost:8080/app/dashboard/actions?x=1#modal",
        visible_label = "Dashboard action",
        discovery_source = "browser-visible",
        evidence_pointer = ".testing/runs/discovery/evidence/dashboard-action",
      },
      {
        id = "settings-a11y",
        name = "Settings",
        route = "/app/settings?tab=profile#main",
        visible_label = "Settings",
        source = "accessibility",
        confidence = "medium",
        evidence_pointer = ".testing/runs/discovery/evidence/settings",
      },
      {
        id = "external",
        name = "External",
        entry_url = "http://127.0.0.1:9999/app/external",
        visible_label = "External",
        discovery_source = "navigation",
        evidence_pointer = ".testing/runs/discovery/evidence/external",
      },
    },
    artifact_root = ".testing/runs/discovery",
    source_ref = { kind = "host-app", ref = "local-app" },
    trace_id = "trace-discovery",
    dedup_key = "dedup-discovery",
  }
  for key, value in pairs(overrides or {}) do payload[key] = value end
  return payload
end

local function ready_result()
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready" },
      { role = "cdp", status = "ready" },
    },
    source_ref = { kind = "testing-discovery-plan", ref = ".testing/runs/discovery" },
  }
end

local function inspect_no_fragment(value)
  local kind = type(value)
  if kind == "string" then
    t.eq(value:find("drop=yes", 1, true), nil)
    t.eq(value:find("view=private", 1, true), nil)
    t.eq(value:find("#", 1, true), nil)
  elseif kind == "table" then
    for key, item in pairs(value) do
      inspect_no_fragment(key)
      inspect_no_fragment(item)
    end
  end
end

return {
  test_code_analysis_is_persisted_deterministically_and_emitted_by_reference = function()
    local artifact_root = ".testing/runs/discovery-code-analysis"
    local fixture_root = prepare_fixture(".testing/fixtures/discovery-code-analysis")
    local payload = scope({
      artifact_root = artifact_root,
      code_analysis = { repository_root = fixture_root },
    })
    local ports = { read_sha256_file = read_sha256_file, sha256_file = sha256_file }
    local first = core.prepare_plan(payload, ports)
    local first_body = read_file(first.code_analysis.artifact_pointer)
    local artifact = code_analysis.load_verified(first.code_analysis, ports)
    local fallback_artifact, fallback_body = code_analysis.load_verified(first.code_analysis, {
      decode = core.json_decode,
      exec_argv = function(argv)
        t.eq(argv[3], "read-hashed-file")
        t.eq(argv[5], first.code_analysis.artifact_pointer)
        return { exit_code = 0, stdout = first.code_analysis.artifact_digest .. "\n" .. first_body, stderr = "" }
      end,
    })

    t.eq(artifact.schema, code_analysis.schema)
    t.eq(fallback_artifact.schema, code_analysis.schema)
    t.eq(fallback_body, first_body)
    t.eq(artifact.version, code_analysis.version)
    t.eq(artifact.file_count, 1)
    t.eq(artifact.facts[1].kind, "file")
    t.eq(artifact.facts[1].source.path, "src/calculator.lua")
    t.eq(artifact.facts[2].kind, "function")
    t.eq(artifact.facts[2].name, "calculate_total")
    t.eq(artifact.facts[2].source.path, "src/calculator.lua")
    t.eq(artifact.facts[2].source.line, 5)
    t.eq(artifact.facts[3].name, "Calculator.compute")

    local second = core.prepare_plan(payload, ports)
    t.eq(read_file(second.code_analysis.artifact_pointer), first_body)
    t.eq(second.code_analysis.artifact_digest, first.code_analysis.artifact_digest)

    local starts = core.module_starts(first, ready_result())
    local event_body = core.json_encode(starts[1])
    t.is_true(event_body:find(first.code_analysis.artifact_pointer, 1, true) ~= nil)
    t.is_true(event_body:find(first.code_analysis.artifact_digest, 1, true) ~= nil)
    t.eq(event_body:find('"facts"', 1, true), nil)
    t.eq(event_body:find("return left + right", 1, true), nil)

    local invalid_scope = core.json_decode(first_body)
    invalid_scope.scope.repository_root = "../outside"
    assert_error_contains(function() code_analysis.validate_artifact(invalid_scope) end, "scope must identify a safe repository tree")
    local invalid_fact = core.json_decode(first_body)
    invalid_fact.facts[1].kind = "unknown"
    assert_error_contains(function() code_analysis.validate_artifact(invalid_fact) end, "fact identity is invalid")

    local supplied_digest = runtime_digest.sha256_file(first.code_analysis.artifact_pointer, {
      exec_argv = function()
        return { exit_code = 0, stdout = first.code_analysis.artifact_digest .. "\n", stderr = "" }
      end,
    })
    t.eq(supplied_digest, first.code_analysis.artifact_digest)
    local saved_exec_argv = _G.exec_argv
    _G.exec_argv = function(request)
      t.eq(request.argv[3], "hash-file")
      return { exit_code = 0, stdout = sha256_file(request.argv[5]) .. "\n", stderr = "" }
    end
    t.eq(runtime_digest.sha256_file(first.code_analysis.artifact_pointer), first.code_analysis.artifact_digest)
    local default_reference = code_analysis.persist(fixture_root, artifact_root .. "/default-code-analysis.json", {
      write = write_file,
    })
    t.eq(default_reference.artifact_digest, sha256_file(default_reference.artifact_pointer))
    _G.exec_argv = saved_exec_argv
    assert_error_contains(function()
      runtime_digest.sha256_file(first.code_analysis.artifact_pointer, {
        exec_argv = function() return { exit_code = 1, stdout = "", stderr = "fixture failure" } end,
      })
    end, "testing-runtime: digest-failed")
    assert_error_contains(function()
      runtime_digest.read_sha256_file(first.code_analysis.artifact_pointer, {
        exec_argv = function() return { exit_code = 1, stdout = "", stderr = "fixture failure" } end,
      })
    end, "testing-runtime: digest-failed")
    assert_error_contains(function()
      runtime_digest.read_sha256_file(first.code_analysis.artifact_pointer, {
        exec_argv = function() return { exit_code = 0, stdout = "malformed", stderr = "" } end,
      })
    end, "testing-runtime: digest-failed")
  end,

  test_code_analysis_loader_rejects_missing_unsupported_and_malformed_artifacts = function()
    local root = ".testing/runs/code-analysis-validation"
    local pointer = root .. "/" .. code_analysis.filename
    local reference = {
      schema = code_analysis.reference_schema,
      artifact_pointer = pointer,
      artifact_digest = string.rep("0", 64),
      artifact_version = code_analysis.version,
    }
    os.remove(pointer)
    assert_error_contains(function() code_analysis.load_verified(reference, { read_sha256_file = read_sha256_file }) end, "code-analysis: artifact-missing")

    local unsupported = {
      schema = reference.schema,
      artifact_pointer = reference.artifact_pointer,
      artifact_digest = reference.artifact_digest,
      artifact_version = 2,
    }
    assert_error_contains(function() code_analysis.load_verified(unsupported, { read_sha256_file = read_sha256_file }) end, "code-analysis: unsupported-version")

    write_file(pointer, "{")
    reference.artifact_digest = sha256_file(pointer)
    assert_error_contains(function() code_analysis.load_verified(reference, { read_sha256_file = read_sha256_file }) end, "code-analysis: malformed-artifact")

    assert_error_contains(function() analyzer.analyze("../outside", pointer) end, "code-analysis: repository-root-invalid")
    assert_error_contains(function()
      core.plan(scope({ code_analysis = { repository_root = "../outside" } }))
    end, "testing-discovery: malformed-request: code_analysis.repository_root")
    assert_error_contains(function()
      core.plan(scope({ mutation_policy = "unbounded" }))
    end, "testing-discovery: malformed-request: mutation_policy is unknown")
    local missing_entry = core.plan(scope({
      observations = {
        {
          id = "missing-entry",
          name = "Missing entry",
          visible_label = "Missing entry",
          discovery_source = "navigation",
          evidence_pointer = ".testing/runs/evidence/missing-entry",
        },
      },
    }))
    t.eq(missing_entry.modules[1].id, "app-discovery")

    local fixture_root = prepare_fixture(".testing/fixtures/code-analysis-decoder")
    local valid_reference, valid_artifact, valid_body = code_analysis.persist(fixture_root, root .. "/decoder.json", { sha256_file = sha256_file })
    local decoder_reference = {
      schema = valid_reference.schema,
      artifact_pointer = valid_reference.artifact_pointer,
      artifact_digest = valid_reference.artifact_digest,
      artifact_version = valid_reference.artifact_version,
    }
    valid_artifact.artifact_pointer = root .. "/other.json"
    for index, fact in ipairs(valid_artifact.facts) do
      fact.pointer = valid_artifact.artifact_pointer .. "#/facts/" .. tostring(index)
    end
    local mismatched_body = code_analysis.canonical_bytes(valid_artifact)
    write_file(valid_reference.artifact_pointer, mismatched_body)
    valid_reference.artifact_digest = sha256_file(valid_reference.artifact_pointer)
    assert_error_contains(function()
      code_analysis.load_verified(valid_reference, { read_sha256_file = read_sha256_file })
    end, "code-analysis: artifact-mismatch")

    local saved_json = _G.json
    _G.json = nil
    assert_error_contains(function()
      code_analysis.load_verified(decoder_reference, {
        read_sha256_file = function() return valid_body, decoder_reference.artifact_digest end,
      })
    end, "code-analysis: malformed-artifact")
    _G.json = saved_json
  end,

  test_code_analysis_loader_hashes_the_same_bytes_it_decodes = function()
    local root = ".testing/runs/code-analysis-exact-bytes"
    local pointer = root .. "/" .. code_analysis.filename
    local fixture_root = prepare_fixture(".testing/fixtures/code-analysis-exact-bytes")
    local reference, artifact, admitted_body = code_analysis.persist(fixture_root, pointer, { sha256_file = sha256_file })
    artifact.scope.repository_root = ".testing/fixtures/code-analysis-authenticated-bytes"
    local authenticated_body = code_analysis.canonical_bytes(artifact)
    write_file(pointer, authenticated_body)
    reference.artifact_digest = sha256_file(pointer)
    write_file(pointer, admitted_body)
    local admitted_digest = sha256_file(pointer)
    t.eq(admitted_digest == reference.artifact_digest, false)

    local split_read_calls, pathname_hash_calls, exact_read_calls = 0, 0, 0
    assert_error_contains(function()
      code_analysis.load_verified(reference, {
        read = function()
          split_read_calls = split_read_calls + 1
          return admitted_body
        end,
        sha256_file = function()
          pathname_hash_calls = pathname_hash_calls + 1
          return reference.artifact_digest
        end,
        read_sha256_file = function(path)
          exact_read_calls = exact_read_calls + 1
          t.eq(path, pointer)
          return admitted_body, admitted_digest
        end,
      })
    end, "code-analysis: digest-mismatch")
    t.eq(split_read_calls, 0)
    t.eq(pathname_hash_calls, 0)
    t.eq(exact_read_calls, 1)
  end,

  test_valid_scope_produces_sanitized_discovery_plan = function()
    local plan = core.plan(scope())
    t.eq(plan.schema, "testing-discovery.plan.v1")
    t.eq(plan.base_url, "http://localhost:8080/app")
    t.eq(plan.allowed_origins[1], "http://localhost:8080")
    t.eq(plan.module_count, 2)
    t.eq(plan.modules[1].id, "dashboard")
    t.eq(#plan.modules[1].observations, 2)
    t.eq(plan.modules[1].observations[2].discovery_source, "browser-visible")
    t.eq(plan.modules[2].id, "settings")
    t.eq(plan.rejected_observation_count, 1)
    t.eq(plan.relation_graph_path, ".testing/runs/discovery/relation-graph.json")
    t.eq(plan.relation_graph.schema, "testing-discovery.relation-graph.v1")
    t.eq(plan.relation_graph.flow_budget, 4)
    t.eq(plan.relation_graph.module_depth, 2)
    t.eq(plan.relation_graph.relations[1].relation_type, "same-nav-cluster")
    inspect_no_fragment(plan)
  end,

  test_no_hand_authored_module_list_is_required = function()
    local plan = core.plan(scope({ budgets = { module_limit = 1, observation_limit = 3, step_budget = 5, case_priorities = { "P0" }, flow_budget = 2, module_depth = 3, relationship_limit = 0 } }))
    t.eq(plan.module_count, 1)
    t.eq(plan.modules[1].id, "dashboard")
    t.eq(plan.budgets.step_budget, 5)
    t.eq(plan.budgets.case_priorities[1], "P0")
    t.eq(plan.budgets.flow_budget, 2)
    t.eq(plan.budgets.module_depth, 3)
    t.eq(plan.budgets.relationship_limit, 0)
    t.eq(plan.relation_graph.relation_count, 0)
  end,

  test_empty_accepted_observations_emit_gap_module = function()
    local plan = core.plan(scope({ observations = {} }))
    t.eq(plan.module_count, 1)
    t.eq(plan.modules[1].id, "app-discovery")
    t.eq(#plan.modules[1].observations, 0)
    t.is_true(plan.limitations[#plan.limitations]:find("gap module", 1, true) ~= nil)
  end,

  test_scope_validation_rejects_non_local_and_missing_base_origin = function()
    t.raises(function()
      core.plan(scope({ base_url = "https://example.invalid/app", allowed_origins = { "https://example.invalid" } }))
    end)
    t.raises(function()
      core.plan(scope({ base_url = "https://localhost:8080/app", allowed_origins = { "https://localhost:8080" } }))
    end)
    t.raises(function()
      core.plan(scope({ allowed_origins = { "http://127.0.0.1:8080" } }))
    end)
  end,

  test_unknown_fields_and_inline_payload_fields_are_rejected = function()
    t.raises(function()
      core.plan(scope({ app_name = "local" }))
    end)
    t.raises(function()
      local payload = scope()
      payload.observations[1].screenshot = "inline-state"
      core.plan(payload)
    end)
  end,

  test_readiness_check_uses_only_readiness_control_fields = function()
    local plan = core.plan(scope())
    local request = core.readiness_check(plan)
    t.eq(request.schema, "browser-readiness.check.v1")
    t.eq(request.base_url, "http://localhost:8080/app")
    t.eq(request.source_ref.kind, "testing-discovery-plan")
    t.eq(request.source_ref.ref, ".testing/runs/discovery")
    t.eq(request.request_context.dry_run, false)
    t.eq(request.request_context.native_argv, nil)
  end,

  test_module_starts_emit_runner_compatible_pointer_only_facts = function()
    local plan = core.plan(scope())
    local starts = core.module_starts(plan, ready_result())
    t.eq(#starts, 2)
    t.eq(starts[1].schema, "testing-pipeline.module-start.v1")
    t.eq(starts[1].backend, "fkst-native")
    t.eq(starts[1].ui_loop.base_url, "http://localhost:8080/app")
    t.eq(starts[1].ui_loop.allowed_origins[1], "http://localhost:8080")
    t.eq(starts[1].ui_loop.platform_flow_ref, ".testing/runs/discovery/relation-graph.json")
    t.eq(starts[1].module_discovery.schema, "testing-runner.module-discovery.v1")
    t.eq(starts[1].module_discovery.observations[1].entry_url, "http://localhost:8080/app/dashboard")
    t.eq(starts[1].cdp_execution.schema, "testing-runner.module-cdp-execution.v1")
    t.eq(starts[1].artifact_root, ".testing/runs/discovery/modules/dashboard")
    inspect_no_fragment(starts)
  end,

  test_plan_artifact_round_trips = function()
    local written = {}
    local plan = core.plan(scope())
    local ok = core.write_plan(plan, function(path, body)
      written[path] = body
      return true
    end)
    t.eq(ok, true)
    t.is_true(written[".testing/runs/discovery/testing-discovery-plan.json"]:find('"relation_graph_path":".testing/runs/discovery/relation-graph.json"', 1, true) ~= nil)
    local decoded = core.read_plan(plan.artifact_root, function(path)
      return written[path]
    end)
    t.eq(decoded.schema, plan.schema)
    t.eq(decoded.module_count, plan.module_count)
    t.eq(decoded.modules[1].id, "dashboard")
    t.eq(decoded.relation_graph.schema, "testing-discovery.relation-graph.v1")
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,
}
