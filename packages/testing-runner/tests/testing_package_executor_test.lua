local contract = require("contract.testing_package_executor")
local package_manifest = require("contract.testing_package_manifest")
local results = require("contract.testing_results")
local executor = require("testing_package_executor.executor")
local runtime_executor = require("testing_runtime.testing_package_executor")
local json = require("testing_runtime.json")
local sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function manifest_fixture(package_content_sha256)
  local manifest = {
    schema = "testing-package-manifest.v1",
    canonicalization = "fkst-testing-package-manifest-canonical-json.v1",
    package_id = "testing-runner",
    package_version = "1.0.0",
    source_commit = "0123456789abcdef0123456789abcdef01234567",
    package_content_sha256 = package_content_sha256,
    supported_contracts = {
      majors = { "testing-runner.v1" },
      canonicalization_profiles = { "fkst-testing-package-manifest-canonical-json.v1" },
    },
    entrypoints = {
      {
        name = "testing-runner.run",
        contract_major = "testing-runner.v1",
        capabilities = { "browser.read-title.v1" },
      },
    },
    semantic_capabilities = { "browser.read-title.v1" },
    runtime_requirements = { lua = "5.4.0", platforms = { "linux-amd64" } },
    dependencies = {
      fkst_packages = { id = "fkst-packages", commit = "abcdef0123456789abcdef0123456789abcdef01" },
      fkst_substrate = { id = "fkst-substrate", commit = "fedcba9876543210fedcba9876543210fedcba98" },
    },
    producer = { name = "fkst-packages-testing", version = "1.0.0", toolchain = "walking-skeleton" },
    creation_metadata = { created_at = "2026-08-21T00:00:00Z", build_id = "executor-walking-skeleton" },
  }
  manifest.manifest_digest = sha256(package_manifest.canonicalize(manifest))
  package_manifest.validate(manifest, nil, sha256)
  return manifest
end

local function documents()
  local package_content_sha256 = sha256("testing-runner-1.0.0 admitted package bytes")
  return {
    package_manifest_ref = manifest_fixture(package_content_sha256),
    source_ref = {
      schema = "testing-package-source.v1",
      source_id = "fixture-home",
      target_url = "http://127.0.0.1:4173/",
    },
    plan_ref = {
      schema = "testing-package-plan.v1",
      case_id = "case-home-title",
      assertion = {
        assertion_id = "assert-home-title",
        expected = "Fixture Home",
        required = true,
        type = "title-equals",
      },
    },
    pql_input_ref = {
      schema = "testing-package-pql-input.v1",
      requirement_id = "REQ-HOME-TITLE",
    },
    policy_ref = {
      schema = "testing-package-policy.v1",
      execution_profile = "browser-deterministic.v1",
      authorized_entrypoint = "testing-runner.run",
      allowed_capabilities = { "browser.read-title.v1" },
    },
    capability_set_ref = {
      schema = "testing-package-capability-set.v1",
      capabilities = { "browser.read-title.v1" },
    },
  }
end

local refs = {
  package_manifest_ref = { kind = "testing-package-manifest", ref = "immutable://packages/testing-runner/1.0.0/manifest.json" },
  source_ref = { kind = "testing-package-source", ref = "immutable://inputs/source.json" },
  plan_ref = { kind = "testing-package-plan", ref = "immutable://inputs/plan.json" },
  pql_input_ref = { kind = "testing-package-pql-input", ref = "immutable://inputs/pql.json" },
  policy_ref = { kind = "testing-package-policy", ref = "immutable://inputs/policy.json" },
  capability_set_ref = { kind = "testing-package-capability-set", ref = "immutable://inputs/capabilities.json" },
}

local function fixture(options)
  options = options or {}
  local docs = documents()
  if options.change_documents then options.change_documents(docs) end
  if options.recompute_manifest_digest then
    docs.package_manifest_ref.manifest_digest = nil
    docs.package_manifest_ref.manifest_digest = sha256(package_manifest.canonicalize(docs.package_manifest_ref))
  end

  local storage, decoded, approved = {}, {}, {}
  for _, field in ipairs(contract.reference_order) do
    local bytes = json.encode(docs[field])
    local ref = refs[field]
    storage[ref.ref] = bytes
    decoded[bytes] = copy(docs[field])
    approved[field] = { kind = ref.kind, ref = ref.ref, sha256 = sha256(bytes) }
  end

  local request = {
    schema = "testing-package-executor.request.v1",
    executor = {
      schema = "testing-package-executor.identity.v1",
      package_id = "testing-runner",
      package_version = "1.0.0",
      package_content_sha256 = docs.package_manifest_ref.package_content_sha256,
      manifest_digest = docs.package_manifest_ref.manifest_digest,
      entrypoint = "testing-runner.run",
      contract_major = "testing-runner.v1",
    },
    execution_profile = "browser-deterministic.v1",
    approved_input_refs = approved,
    trace_id = "trace-walking-skeleton",
    dedup_key = "dedup-walking-skeleton",
  }

  local calls = { loads = {}, freshness = {}, browser = {}, writes = {}, now = 0 }
  local clock = { "2026-08-21T00:00:00Z", "2026-08-21T00:00:01Z" }
  local ports = {
    load_immutable = function(ref)
      table.insert(calls.loads, copy(ref))
      return assert(storage[ref.ref], "unknown immutable ref " .. tostring(ref.ref))
    end,
    sha256 = sha256,
    decode_json = function(bytes)
      return copy(assert(decoded[bytes], "unknown canonical JSON bytes"))
    end,
    check_freshness = function(check)
      table.insert(calls.freshness, copy(check))
      return options.freshness ~= false
    end,
    browser_read_title = function(effect_request)
      table.insert(calls.browser, copy(effect_request))
      return {
        schema = "testing-package-executor.effect-receipt.v1",
        effect_id = "effect-case-home-title-title",
        status = "succeeded",
        observed_title = options.observed_title or "Fixture Home",
        evidence_refs = {},
      }
    end,
    write_canonical = function(write_request)
      table.insert(calls.writes, copy(write_request))
      return {
        schema = "testing-package-executor.write-receipt.v1",
        status = "written",
        ref = {
          kind = "artifact",
          ref = ".testing/runs/dedup-walking-skeleton/case-result.json",
          sha256 = write_request.canonical_sha256,
        },
      }
    end,
    now = function()
      calls.now = calls.now + 1
      return clock[calls.now]
    end,
  }
  return {
    docs = docs,
    storage = storage,
    decoded = decoded,
    request = request,
    ports = ports,
    calls = calls,
  }
end

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local function assert_zero_execution_effects(value)
  t.eq(#value.calls.freshness, 0)
  t.eq(#value.calls.browser, 0)
  t.eq(#value.calls.writes, 0)
end

local function assert_semantics(actual, expected)
  t.eq(actual.case_result.execution_status, expected.case_result.execution_status)
  t.eq(actual.case_result.classification, expected.case_result.classification)
  t.eq(actual.case_result.observations, expected.case_result.observations)
  t.eq(actual.case_result.assertions, expected.case_result.assertions)
end

return {
  test_runtime_adapter_executes_the_full_walking_skeleton = function()
    local value = fixture()
    local execution = runtime_executor.execute(value.request, value.ports)

    t.eq(value.calls.loads, {
      value.request.approved_input_refs.package_manifest_ref,
      value.request.approved_input_refs.source_ref,
      value.request.approved_input_refs.plan_ref,
      value.request.approved_input_refs.pql_input_ref,
      value.request.approved_input_refs.policy_ref,
      value.request.approved_input_refs.capability_set_ref,
    })
    t.eq(#value.calls.freshness, 1)
    t.eq(value.calls.freshness[1], {
      schema = "testing-package-executor.freshness-check.v1",
      dedup_key = "dedup-walking-skeleton",
      effect_id = "effect-case-home-title-title",
    })
    t.eq(#value.calls.browser, 1)
    t.eq(value.calls.browser[1], {
      schema = "testing-package-executor.browser-read-title.v1",
      effect_id = "effect-case-home-title-title",
      url = "http://127.0.0.1:4173/",
    })
    t.eq(#value.calls.writes, 1)
    t.eq(sha256(value.calls.writes[1].canonical_bytes), value.calls.writes[1].canonical_sha256)
    t.eq(results.canonicalize(execution.case_result), value.calls.writes[1].canonical_bytes)
    t.eq(execution.schema, "testing-package-executor.execution.v1")
    t.eq(execution.case_result.execution_status, "passed")
    t.eq(execution.case_result.classification, "deterministic")
    t.eq(execution.case_result.timing, {
      started_at = "2026-08-21T00:00:00Z",
      completed_at = "2026-08-21T00:00:01Z",
      duration_ms = 1000,
    })
    t.eq(execution.case_result_ref, {
      kind = "artifact",
      ref = ".testing/runs/dedup-walking-skeleton/case-result.json",
      sha256 = value.calls.writes[1].canonical_sha256,
    })
  end,

  test_direct_and_runtime_adapter_execution_have_equal_semantics = function()
    local direct_fixture = fixture()
    local resolved = executor.resolve(direct_fixture.request, direct_fixture.ports)
    local direct = executor.execute(resolved, direct_fixture.ports)
    local adapter_fixture = fixture()
    local adapted = runtime_executor.execute(adapter_fixture.request, adapter_fixture.ports)
    assert_semantics(direct, adapted)
  end,

  test_unequal_title_produces_canonical_assertion_failure = function()
    local value = fixture({ observed_title = "Unexpected Home" })
    local execution = runtime_executor.execute(value.request, value.ports)
    t.eq(execution.case_result.execution_status, "failed")
    t.eq(execution.case_result.classification, "assertion_failure")
    t.eq(execution.case_result.observations[1].value, "Unexpected Home")
    t.eq(execution.case_result.assertions[1].status, "failed")
    t.eq(execution.case_result.assertions[1].classification, "assertion_failure")
    t.eq(#value.calls.writes, 1)
  end,

  test_tampered_approved_bytes_fail_before_execution_effects = function()
    for _, field in ipairs(contract.reference_order) do
      local value = fixture()
      local ref = value.request.approved_input_refs[field].ref
      value.storage[ref] = value.storage[ref] .. " "
      expect_failure("digest-mismatch", function() runtime_executor.execute(value.request, value.ports) end)
      assert_zero_execution_effects(value)
    end
  end,

  test_manifest_mapping_conflicts_fail_without_execution_effects = function()
    local variants = {
      function(manifest) manifest.entrypoints = {} end,
      function(manifest) table.insert(manifest.entrypoints, copy(manifest.entrypoints[1])) end,
      function(manifest)
        manifest.entrypoints = {
          { name = "testing-runner.supervise", contract_major = "testing-runner.v1", capabilities = { "browser.read-title.v1" } },
        }
      end,
      function(manifest)
        manifest.entrypoints[1].capabilities = { "browser.unknown.v1" }
        manifest.semantic_capabilities = { "browser.unknown.v1" }
      end,
    }
    for _, mutate in ipairs(variants) do
      local value = fixture({
        change_documents = function(docs) mutate(docs.package_manifest_ref) end,
        recompute_manifest_digest = true,
      })
      value.request.executor.manifest_digest = value.docs.package_manifest_ref.manifest_digest
      expect_failure("mismatch", function() runtime_executor.execute(value.request, value.ports) end)
      assert_zero_execution_effects(value)
    end
  end,

  test_additional_nonmatching_manifest_entrypoint_does_not_create_global_singleton_rule = function()
    local value = fixture({
      change_documents = function(docs)
        table.insert(docs.package_manifest_ref.entrypoints, {
          name = "testing-runner.supervise",
          contract_major = "testing-runner.v1",
          capabilities = { "browser.read-title.v1" },
        })
      end,
      recompute_manifest_digest = true,
    })
    value.request.executor.manifest_digest = value.docs.package_manifest_ref.manifest_digest
    local execution = runtime_executor.execute(value.request, value.ports)
    t.eq(execution.case_result.execution_status, "passed")
  end,

  test_capability_set_mismatch_fails_without_execution_effects = function()
    local value = fixture({
      change_documents = function(docs) docs.capability_set_ref.capabilities = { "browser.unknown.v1" } end,
    })
    expect_failure("mapping-mismatch", function() runtime_executor.execute(value.request, value.ports) end)
    assert_zero_execution_effects(value)
  end,

  test_closed_request_rejects_host_and_authority_fields = function()
    for _, field in ipairs({ "argv", "env", "token", "credential", "cdp_url", "workspace_path" }) do
      local value = fixture()
      value.request[field] = "untrusted"
      expect_failure("unsupported field " .. field, function() runtime_executor.execute(value.request, value.ports) end)
      t.eq(#value.calls.loads, 0)
      assert_zero_execution_effects(value)
    end
  end,

  test_freshness_denial_prevents_browser_and_writer_calls = function()
    local value = fixture({ freshness = false })
    expect_failure("freshness-denied", function() runtime_executor.execute(value.request, value.ports) end)
    t.eq(#value.calls.loads, 6)
    t.eq(#value.calls.freshness, 1)
    t.eq(#value.calls.browser, 0)
    t.eq(#value.calls.writes, 0)
  end,

  test_missing_ports_fail_closed = function()
    local value = fixture()
    value.ports.decode_json = nil
    expect_failure("decode_json must be callable", function() runtime_executor.execute(value.request, value.ports) end)
    t.eq(#value.calls.loads, 0)

    value = fixture()
    local resolved = executor.resolve(value.request, value.ports)
    value.ports.browser_read_title = nil
    expect_failure("browser_read_title must be callable", function() executor.execute(resolved, value.ports) end)
    t.eq(#value.calls.freshness, 0)
    t.eq(#value.calls.writes, 0)
  end,
}
