local contract = require("contract.testing_package_executor")
local error_facts = require("contract.error_facts")
local package_manifest = require("contract.testing_package_manifest")
local results = require("contract.testing_results")
local executor = require("testing_package_executor.executor")
local runtime_executor = require("testing_runtime.testing_package_executor")
local host_json = json
local runtime_json = require("testing_runtime.json")
local sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test

local request_fixture_root = "packages/testing-runner/tests/fixtures/testing-package-executor.request.v1"
local request_fixture_names = {
  "valid-complete",
  "invalid-top-level-unknown", "invalid-top-level-missing-dedup-key",
  "invalid-request-schema", "invalid-identity-schema",
  "invalid-executor-missing-package-id", "invalid-executor-extra-field",
  "invalid-identity-package-id-non-string", "invalid-identity-entrypoint-empty",
  "invalid-identity-contract-major-control", "invalid-identity-package-id-del",
  "invalid-identity-package-id-over-byte-limit",
  "invalid-identity-package-id-multibyte-over-byte-limit",
  "invalid-execution-profile-empty", "invalid-trace-id-del",
  "invalid-dedup-key-over-byte-limit", "invalid-semver-two-components",
  "invalid-semver-prefixed", "invalid-digest-short", "invalid-digest-uppercase",
  "invalid-digest-non-hex", "invalid-approved-refs-missing-policy",
  "invalid-approved-refs-extra", "invalid-package-manifest-kind",
  "invalid-source-kind", "invalid-plan-kind", "invalid-pql-input-kind",
  "invalid-policy-kind", "invalid-capability-set-kind", "invalid-ref-empty",
  "invalid-ref-mutable", "invalid-ref-query", "invalid-ref-fragment",
  "invalid-ref-control", "invalid-ref-del", "invalid-ref-over-byte-limit",
  "invalid-ref-multibyte-over-byte-limit", "invalid-reference-missing-sha256",
  "invalid-reference-extra-field", "invalid-forbidden-execution-fields",
  "invalid-forbidden-secret-fields", "invalid-forbidden-path-loader-fields",
  "invalid-forbidden-browser-fields", "invalid-forbidden-talos-fields",
  "invalid-forbidden-resolved-entrypoint",
  "contextual-unsupported-execution-profile",
  "contextual-unsupported-executor-mapping",
}

local function request_fixture(name)
  local handle = assert(io.open(request_fixture_root .. "/" .. name .. ".json", "rb"))
  local body = handle:read("*a")
  handle:close()
  return host_json.decode(body)
end

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
    local bytes = runtime_json.encode(docs[field])
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

  local calls = {
    loads = {}, package_loads = {}, compatibility = {}, admissions = {},
    completed_queries = {}, claims = {}, freshness = {}, intents = {}, browser = {}, receipts = {}, writes = {}, completions = {}, now = 0,
  }
  local package_content_bytes = options.package_content_bytes or "testing-runner-1.0.0 admitted package bytes"
  local receipt_store = options.receipt_store or {}
  local completed_store = options.completed_store or {}
  local clock = { "2026-08-21T00:00:00Z", "2026-08-21T00:00:01Z" }
  local ports = {
    load_immutable = function(ref)
      table.insert(calls.loads, copy(ref))
      return assert(storage[ref.ref], "unknown immutable ref " .. tostring(ref.ref))
    end,
    load_package_content = function(identity)
      table.insert(calls.package_loads, copy(identity))
      return package_content_bytes
    end,
    sha256 = sha256,
    check_runtime_compatibility = function(compatibility)
      table.insert(calls.compatibility, copy(compatibility))
      return options.runtime_compatible ~= false
        and compatibility.runtime_requirements.lua == "5.4.0"
        and #compatibility.runtime_requirements.platforms == 1
        and compatibility.runtime_requirements.platforms[1] == "linux-amd64"
        and compatibility.dependencies.fkst_packages.commit == "abcdef0123456789abcdef0123456789abcdef01"
        and compatibility.dependencies.fkst_substrate.commit == "fedcba9876543210fedcba9876543210fedcba98"
    end,
    decode_json = function(bytes)
      return copy(assert(decoded[bytes], "unknown canonical JSON bytes"))
    end,
    admit_resolution = function(admission_request)
      table.insert(calls.admissions, copy(admission_request))
      local existing = receipt_store[admission_request.admission_key]
      if existing ~= nil and existing.admission_digest ~= admission_request.admission_digest then
        return {
          schema = contract.schemas.admission_conflict,
          status = "conflict",
          admission_key = admission_request.admission_key,
          admitted_digest = existing.admission_digest,
          attempted_digest = admission_request.admission_digest,
        }
      end
      if existing ~= nil then return copy(existing) end
      local receipt = {
        schema = contract.schemas.admission_receipt,
        status = "admitted",
        admission_key = admission_request.admission_key,
        admission_digest = admission_request.admission_digest,
      }
      receipt_store[admission_request.admission_key] = copy(receipt)
      return receipt
    end,
    load_completed_execution = function(query)
      table.insert(calls.completed_queries, copy(query))
      return copy(completed_store[query.dedup_key .. ":" .. query.admission_digest])
    end,
    claim_execution = function(request)
      table.insert(calls.claims, copy(request))
      return { schema=contract.schemas.execution_claim_receipt, status="claimed", dedup_key=request.dedup_key,
        admission_digest=request.admission_digest, claim_id="claim-" .. request.dedup_key }
    end,
    check_freshness = function(check)
      table.insert(calls.freshness, copy(check))
      return options.freshness ~= false
    end,
    persist_effect_intent = function(intent)
      table.insert(calls.intents, copy(intent))
      return true
    end,
    browser_read_title = function(effect_request)
      table.insert(calls.browser, copy(effect_request))
      return {
        schema = "testing-package-executor.effect-receipt.v1",
        effect_id = "effect-case-home-title-title",
        status = "succeeded",
        observed_url = "http://127.0.0.1:4173/",
        observed_title = options.observed_title or "Fixture Home",
        evidence_refs = { { kind="artifact", ref=".testing/runs/dedup-walking-skeleton/evidence/title.json", sha256=sha256(string.rep("x", 123)) } },
        evidence_size_bytes = 123,
      }
    end,
    persist_effect_receipt = function(receipt)
      table.insert(calls.receipts, copy(receipt))
      return true
    end,
    write_canonical = function(write_request)
      table.insert(calls.writes, copy(write_request))
      return {
        schema = "testing-package-executor.write-receipt.v1",
        status = "written",
        ref = {
          kind = "artifact",
          ref = ".testing/runs/dedup-walking-skeleton/" .. (write_request.kind == "evidence-manifest" and "evidence-manifest.json" or "case-result-set.json"),
          sha256 = options.writer_digest or sha256(write_request.canonical_bytes),
        },
      }
    end,
    complete_execution = function(receipt)
      table.insert(calls.completions, copy(receipt))
      completed_store[receipt.dedup_key .. ":" .. receipt.admission_digest] = copy(receipt)
      return copy(receipt)
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
    receipt_store = receipt_store,
    completed_store = completed_store,
  }
end

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  if fragment ~= nil then t.is_true(tostring(err):find(fragment, 1, true) ~= nil) end
end

local function assert_zero_execution_effects(value)
  t.eq(value.calls.now, 0)
  t.eq(#value.calls.completed_queries, 0)
  t.eq(#value.calls.claims, 0)
  t.eq(#value.calls.freshness, 0)
  t.eq(#value.calls.intents, 0)
  t.eq(#value.calls.receipts, 0)
  t.eq(#value.calls.completions, 0)
  t.eq(#value.calls.browser, 0)
  t.eq(#value.calls.writes, 0)
end

local function assert_semantics(actual, expected)
  t.eq(runtime_json.encode(actual), runtime_json.encode(expected))
end

return {
  test_shared_request_schema_fixtures_match_runtime_validation = function()
    for _, name in ipairs(request_fixture_names) do
      local shared = request_fixture(name)
      t.eq(shared.case, name)
      t.eq(type(shared.portable_valid), "boolean")
      t.eq(type(shared.runtime_valid), "boolean")
      t.eq(type(shared.resolver_error), "string")
      t.eq(type(shared.request), "table")

      local ok, result = pcall(function()
        return contract.validate_request(shared.request)
      end)
      t.eq(ok, shared.runtime_valid)
      if ok then t.eq(result, shared.request) end
    end
  end,

  test_contextual_request_fixtures_are_rejected_only_by_resolver_mapping = function()
    local profile = request_fixture("contextual-unsupported-execution-profile")
    local value = fixture()
    value.request.execution_profile = profile.request.execution_profile
    contract.validate_request(value.request)
    local ok, err = pcall(function() runtime_executor.resolve(value.request, value.ports) end)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(err), profile.resolver_error)

    local mapping = request_fixture("contextual-unsupported-executor-mapping")
    value = fixture({
      change_documents = function(docs)
        docs.package_manifest_ref.package_id = mapping.request.executor.package_id
        docs.package_manifest_ref.supported_contracts.majors[1] = mapping.request.executor.contract_major
        docs.package_manifest_ref.entrypoints[1].name = mapping.request.executor.entrypoint
        docs.package_manifest_ref.entrypoints[1].contract_major = mapping.request.executor.contract_major
      end,
      recompute_manifest_digest = true,
    })
    value.request.executor.package_id = mapping.request.executor.package_id
    value.request.executor.entrypoint = mapping.request.executor.entrypoint
    value.request.executor.contract_major = mapping.request.executor.contract_major
    contract.validate_request(value.request)
    ok, err = pcall(function() runtime_executor.resolve(value.request, value.ports) end)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(err), mapping.resolver_error)
  end,

  test_runtime_adapter_resolve_exposes_resolved_invocation = function()
    local value = fixture()
    local resolved = runtime_executor.resolve(value.request, value.ports)
    t.eq(resolved.schema, contract.schemas.resolved_invocation)
    t.eq(resolved.selected_entrypoint.executor_id, contract.executor_id)
    t.eq(resolved.admission_receipt.admission_digest, resolved.admission_digest)
    t.eq(#value.calls.loads, 6)
    t.eq(#value.calls.package_loads, 1)
    t.eq(#value.calls.compatibility, 1)
    t.eq(#value.calls.admissions, 1)
  end,


  test_same_key_replays_receipt_and_different_digest_conflicts = function()
    local receipt_store = {}
    local first = fixture({ receipt_store = receipt_store })
    local admitted = runtime_executor.resolve(first.request, first.ports)
    local replayed = runtime_executor.resolve(first.request, first.ports)
    t.eq(runtime_json.encode(replayed.admission_receipt), runtime_json.encode(admitted.admission_receipt))
    t.eq(#first.calls.admissions, 2)

    local conflict = fixture({
      receipt_store = receipt_store,
    completed_store = completed_store,
      change_documents = function(docs) docs.package_manifest_ref.source_commit = string.rep("9", 40) end,
      recompute_manifest_digest = true,
    })
    local conflict_receipt = runtime_executor.execute(conflict.request, conflict.ports)
    t.eq(conflict_receipt.schema, contract.schemas.admission_conflict)
    t.eq(conflict_receipt.status, "conflict")
    t.eq(conflict_receipt.admitted_digest, admitted.admission_digest)
    t.eq(conflict_receipt.attempted_digest, conflict.calls.admissions[1].admission_digest)
    t.eq(#conflict.calls.admissions, 1)
    assert_zero_execution_effects(conflict)
  end,

  test_package_content_runtime_and_mapping_authority_fail_before_admission = function()
    local package_mismatch = fixture({ package_content_bytes = "different package bytes" })
    expect_failure("package-content-mismatch", function()
      runtime_executor.execute(package_mismatch.request, package_mismatch.ports)
    end)
    t.eq(#package_mismatch.calls.admissions, 0)
    assert_zero_execution_effects(package_mismatch)

    local incompatible = fixture({ runtime_compatible = false })
    expect_failure("runtime-incompatible", function()
      runtime_executor.execute(incompatible.request, incompatible.ports)
    end)
    t.eq(#incompatible.calls.admissions, 0)
    assert_zero_execution_effects(incompatible)

    for _, mutate in ipairs({
      function(manifest) manifest.runtime_requirements.lua = "5.5.0" end,
      function(manifest) manifest.runtime_requirements.platforms[1] = "darwin-arm64" end,
      function(manifest) manifest.dependencies.fkst_packages.commit = string.rep("1", 40) end,
      function(manifest) manifest.dependencies.fkst_substrate.commit = string.rep("2", 40) end,
    }) do
      local incompatible_manifest = fixture({
        change_documents = function(docs) mutate(docs.package_manifest_ref) end,
        recompute_manifest_digest = true,
      })
      incompatible_manifest.request.executor.manifest_digest = incompatible_manifest.docs.package_manifest_ref.manifest_digest
      expect_failure("runtime-incompatible", function()
        runtime_executor.resolve(incompatible_manifest.request, incompatible_manifest.ports)
      end)
      t.eq(#incompatible_manifest.calls.admissions, 0)
    end

    local malformed_package_sha = fixture()
    local valid_package_sha = malformed_package_sha.ports.sha256
    malformed_package_sha.ports.sha256 = function(bytes)
      if bytes == "testing-runner-1.0.0 admitted package bytes" then return "bad" end
      return valid_package_sha(bytes)
    end
    expect_failure("sha256-failed", function()
      runtime_executor.resolve(malformed_package_sha.request, malformed_package_sha.ports)
    end)
    t.eq(#malformed_package_sha.calls.admissions, 0)

    local caller_selected_entrypoint = fixture({
      change_documents = function(docs)
        table.insert(docs.package_manifest_ref.entrypoints, {
          name = "testing-runner.supervise",
          contract_major = "testing-runner.v1",
          capabilities = { "browser.read-title.v1" },
        })
      end,
      recompute_manifest_digest = true,
    })
    caller_selected_entrypoint.request.executor.entrypoint = "testing-runner.supervise"
    caller_selected_entrypoint.request.executor.manifest_digest = caller_selected_entrypoint.docs.package_manifest_ref.manifest_digest
    expect_failure("unsupported-mapping", function()
      runtime_executor.resolve(caller_selected_entrypoint.request, caller_selected_entrypoint.ports)
    end)
    t.eq(#caller_selected_entrypoint.calls.admissions, 0)

    local unsupported_version = fixture({
      change_documents = function(docs) docs.package_manifest_ref.package_version = "9.9.9" end,
      recompute_manifest_digest = true,
    })
    unsupported_version.request.executor.package_version = "9.9.9"
    unsupported_version.request.executor.manifest_digest = unsupported_version.docs.package_manifest_ref.manifest_digest
    expect_failure("unsupported-mapping", function()
      runtime_executor.resolve(unsupported_version.request, unsupported_version.ports)
    end)
    t.eq(#unsupported_version.calls.admissions, 0)

    local duplicate = copy(contract.semantic_mappings[1])
    table.insert(contract.semantic_mappings, duplicate)
    local ambiguous = fixture()
    local ok, err = pcall(runtime_executor.resolve, ambiguous.request, ambiguous.ports)
    table.remove(contract.semantic_mappings)
    t.eq(ok, false)
    t.eq(error_facts.error_class_from_message(err), "mapping-ambiguous")
    t.eq(#ambiguous.calls.admissions, 0)
  end,

  test_resolved_invocation_recomputes_admission_before_effects = function()
    for _, mutate in ipairs({
      function(resolved) resolved.executor.package_version = "9.9.9" end,
      function(resolved) resolved.approved_input_refs.plan_ref.sha256 = string.rep("f", 64) end,
    }) do
      local value = fixture()
      local resolved = runtime_executor.resolve(value.request, value.ports)
      mutate(resolved)
      expect_failure("admission-mismatch", function() executor.execute(resolved, value.ports) end)
      assert_zero_execution_effects(value)
    end
  end,

  test_resolver_failure_receipts_are_stable_and_effect_free = function()
    local value = fixture()
    value.storage[value.request.approved_input_refs.plan_ref.ref] = "tampered"
    local ok, resolver_error = pcall(runtime_executor.resolve, value.request, value.ports)
    t.eq(ok, false)
    local failure = runtime_executor.failure_receipt(value.request, resolver_error)
    t.eq(failure.schema, contract.schemas.resolver_failure)
    t.eq(failure.status, "rejected")
    t.eq(failure.admission_key, value.request.dedup_key)
    t.eq(failure.code, "digest-mismatch")
    t.eq(#value.calls.admissions, 0)
    assert_zero_execution_effects(value)

    for _, request in ipairs({
      {},
      { dedup_key = 42 },
      { dedup_key = {} },
      { dedup_key = string.rep("x", 181) },
      { dedup_key = "bad\nkey" },
    }) do
      local projected = runtime_executor.failure_receipt(request, "unclassified failure")
      t.eq(projected.admission_key, "unknown")
      t.eq(projected.code, "caught-failure")
    end
    t.eq(runtime_executor.failure_receipt(nil, "unclassified failure").admission_key, "unknown")
  end,

  test_runtime_adapter_executes_and_replays_the_full_walking_skeleton = function()
    local value = fixture()
    local completed = runtime_executor.execute(value.request, value.ports)
    local replayed = runtime_executor.execute(value.request, value.ports)

    t.eq(completed.schema, contract.schemas.completed_execution)
    t.eq(runtime_json.encode(replayed), runtime_json.encode(completed))
    t.eq(#value.calls.completed_queries, 2)
    t.eq(#value.calls.claims, 1)
    t.eq(#value.calls.freshness, 1)
    t.eq(#value.calls.intents, 1)
    t.eq(#value.calls.browser, 1)
    t.eq(#value.calls.receipts, 1)
    t.eq(#value.calls.writes, 2)
    t.eq(value.calls.writes[1].kind, "evidence-manifest")
    t.eq(value.calls.writes[2].kind, "case-result-set")
    t.eq(#value.calls.completions, 1)
    t.eq(value.calls.now, 2)
  end,

  test_writer_receipt_digest_must_match_submitted_canonical_bytes = function()
    local value = fixture({ writer_digest = string.rep("0", 64) })
    expect_failure("digest-mismatch", function() runtime_executor.execute(value.request, value.ports) end)
    t.eq(#value.calls.writes, 1)
    t.eq(#value.calls.completions, 0)
  end,

  test_direct_and_runtime_adapter_execution_have_equal_semantics = function()
    local direct_fixture = fixture()
    local resolved = runtime_executor.resolve(direct_fixture.request, direct_fixture.ports)
    local direct = executor.execute(resolved, direct_fixture.ports)
    local adapter_fixture = fixture()
    local adapted = runtime_executor.execute(adapter_fixture.request, adapter_fixture.ports)
    assert_semantics(direct, adapted)
  end,

  test_unequal_title_is_rejected_before_canonical_writes = function()
    local value = fixture({ observed_title = "Unexpected Home" })
    expect_failure("outside this walking skeleton", function() runtime_executor.execute(value.request, value.ports) end)
    t.eq(#value.calls.browser, 1)
    t.eq(#value.calls.receipts, 1)
    t.eq(#value.calls.writes, 0)
    t.eq(#value.calls.completions, 0)
  end,

  test_tampered_approved_bytes_fail_before_execution_effects = function()
    for _, field in ipairs(contract.reference_order) do
      local value = fixture()
      local ref = value.request.approved_input_refs[field].ref
      value.storage[ref] = value.storage[ref] .. " "
      expect_failure("digest-mismatch", function() runtime_executor.execute(value.request, value.ports) end)
      t.eq(#value.calls.admissions, 0)
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
      expect_failure(nil, function() runtime_executor.execute(value.request, value.ports) end)
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
    t.eq(execution.status, "completed")
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

  test_manifest_executor_validator_failure_matrix = function()
    local value = fixture()
    local function rejects(fn) t.raises(fn) end
    rejects(function() contract.validate_request({}) end)
    local identity = copy(value.request.executor); identity.package_version = "1.0"
    rejects(function() contract.validate_identity(identity) end)
    identity = copy(value.request.executor); identity.package_content_sha256 = "A" .. string.rep("a", 63)
    rejects(function() contract.validate_identity(identity) end)
    identity = copy(value.request.executor); identity.package_id = ""
    rejects(function() contract.validate_identity(identity) end)
    local ref = copy(value.request.approved_input_refs.source_ref); ref.kind = "wrong"
    rejects(function() contract.validate_reference(ref, "source_ref", "testing-package-source") end)
    ref = copy(value.request.approved_input_refs.source_ref); ref.ref = "workspace://mutable"
    rejects(function() contract.validate_reference(ref, "source_ref", "testing-package-source") end)
    local source = copy(value.docs.source_ref); source.source_id = "other"; rejects(function() contract.validate_source(source) end)
    source = copy(value.docs.source_ref); source.target_url = "http://127.0.0.1:4173/?x=1"; rejects(function() contract.validate_source(source) end)
    local plan = copy(value.docs.plan_ref); plan.case_id = "other"; rejects(function() contract.validate_plan(plan) end)
    plan = copy(value.docs.plan_ref); plan.assertion.assertion_id = "other"; rejects(function() contract.validate_plan(plan) end)
    plan = copy(value.docs.plan_ref); plan.assertion.type = "other"; rejects(function() contract.validate_plan(plan) end)
    local freshness = { schema=contract.schemas.freshness_check, dedup_key=value.request.dedup_key, effect_id="other" }
    rejects(function() contract.validate_freshness_check(freshness) end)
    local sparse = { [1] = contract.capability, [3] = "other" }
    rejects(function() contract.validate_policy({schema=contract.schemas.policy,execution_profile=contract.profile,authorized_entrypoint=contract.entrypoint,allowed_capabilities=sparse}) end)
    rejects(function() contract.validate_policy({schema=contract.schemas.policy,execution_profile=contract.profile,authorized_entrypoint=contract.entrypoint,allowed_capabilities={}}) end)
    local effect = { schema=contract.schemas.browser_read_title, effect_id="other", url=contract.target_url }
    rejects(function() contract.validate_browser_read_title(effect) end)
    effect.effect_id=contract.effect_id; effect.url="http://127.0.0.1:4173/other"; rejects(function() contract.validate_browser_read_title(effect) end)
    local receipt = { schema=contract.schemas.effect_receipt, effect_id="other", status="succeeded", observed_title="Fixture Home", evidence_refs={} }
    rejects(function() contract.validate_effect_receipt(receipt) end)
    receipt.effect_id=contract.effect_id; receipt.status="failed"
    rejects(function() contract.validate_effect_receipt(receipt) end)
    local write = { schema=contract.schemas.write_receipt, status="failed", ref={kind="artifact",ref="x",sha256=string.rep("a",64)} }
    rejects(function() contract.validate_write_receipt(write) end)
    write.status="written"; write.ref.kind="wrong"; rejects(function() contract.validate_write_receipt(write) end)
    receipt.status="succeeded"
    local execution = { schema=contract.schemas.execution, case_result={}, effect_receipt=receipt, case_result_ref={kind="wrong",ref="x",sha256=string.rep("a",64)} }
    rejects(function() contract.validate_execution(execution) end)

    local admission_digest = string.rep("a", 64)
    local admission_receipt = {
      schema=contract.schemas.admission_receipt, status="admitted",
      admission_key="admission-key", admission_digest=admission_digest,
    }
    admission_receipt.status="wrong"
    rejects(function() contract.validate_admission_receipt(admission_receipt, "admission-key", admission_digest) end)
    admission_receipt.status="admitted"; admission_receipt.admission_key="wrong"
    rejects(function() contract.validate_admission_receipt(admission_receipt, "admission-key", admission_digest) end)
    admission_receipt.admission_key="admission-key"; admission_receipt.schema="wrong"
    rejects(function() contract.validate_admission_receipt(admission_receipt, "admission-key", admission_digest) end)

    local admission_conflict = {
      schema=contract.schemas.admission_conflict, status="conflict",
      admission_key="admission-key", admitted_digest=string.rep("b", 64),
      attempted_digest=admission_digest,
    }
    admission_conflict.status="wrong"
    rejects(function() contract.validate_admission_conflict(admission_conflict, "admission-key", admission_digest) end)
    admission_conflict.status="conflict"; admission_conflict.admission_key="wrong"
    rejects(function() contract.validate_admission_conflict(admission_conflict, "admission-key", admission_digest) end)
    admission_conflict.admission_key="admission-key"; admission_conflict.attempted_digest=string.rep("c", 64)
    rejects(function() contract.validate_admission_conflict(admission_conflict, "admission-key", admission_digest) end)
    admission_conflict.attempted_digest=admission_digest; admission_conflict.admitted_digest="bad"
    rejects(function() contract.validate_admission_conflict(admission_conflict, "admission-key", admission_digest) end)
    admission_conflict.admitted_digest=admission_digest
    rejects(function() contract.validate_admission_conflict(admission_conflict, "admission-key", admission_digest) end)

    local resolver_failure = {
      schema=contract.schemas.resolver_failure, status="wrong",
      admission_key="admission-key", code="caught-failure",
    }
    rejects(function() contract.validate_resolver_failure(resolver_failure) end)
    resolver_failure.status="rejected"; resolver_failure.schema=contract.schemas.resolver_failure; resolver_failure.code="unknown"
    rejects(function() contract.validate_resolver_failure(resolver_failure) end)

    local bad_admission_sha = fixture()
    local valid_sha256 = bad_admission_sha.ports.sha256
    bad_admission_sha.ports.sha256 = function(bytes)
      if type(bytes) == "string" and bytes:find(contract.schemas.admission_request, 1, true) then return "bad" end
      return valid_sha256(bytes)
    end
    rejects(function() runtime_executor.resolve(bad_admission_sha.request, bad_admission_sha.ports) end)

    local bad = fixture(); bad.ports.sha256 = function() return "bad" end
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    bad = fixture(); bad.request.execution_profile = "other"
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    bad = fixture({ change_documents=function(docs)
      docs.package_manifest_ref.semantic_capabilities = { "other" }
      docs.package_manifest_ref.entrypoints[1].capabilities = { "other" }
    end })
    bad.docs.package_manifest_ref.manifest_digest = nil
    bad.docs.package_manifest_ref.manifest_digest = sha256(package_manifest.canonicalize(bad.docs.package_manifest_ref))
    bad.request.executor.manifest_digest = bad.docs.package_manifest_ref.manifest_digest
    local manifest_ref = bad.request.approved_input_refs.package_manifest_ref
    bad.storage[manifest_ref.ref] = runtime_json.encode(bad.docs.package_manifest_ref)
    manifest_ref.sha256 = sha256(bad.storage[manifest_ref.ref])
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    bad = fixture(); bad.request.executor.package_content_sha256 = string.rep("f", 64)
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    bad = fixture(); bad.request.executor.manifest_digest = string.rep("f", 64)
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    bad = fixture({ change_documents=function(docs)
      docs.package_manifest_ref.semantic_capabilities = { "other" }
    end })
    bad.docs.package_manifest_ref.manifest_digest = nil
    bad.docs.package_manifest_ref.manifest_digest = sha256(package_manifest.canonicalize(bad.docs.package_manifest_ref))
    bad.request.executor.manifest_digest = bad.docs.package_manifest_ref.manifest_digest
    bad.request.approved_input_refs.package_manifest_ref.sha256 = sha256(runtime_json.encode(bad.docs.package_manifest_ref))
    bad.storage[bad.request.approved_input_refs.package_manifest_ref.ref] = runtime_json.encode(bad.docs.package_manifest_ref)
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    local resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.executor.package_id = "other"
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.execution_profile = "other"
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.selected_entrypoint.name = "other"
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.selected_entrypoint.contract_major = "other"
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.selected_entrypoint.executor_id = "other"
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.admission_receipt.admission_digest = string.rep("f", 64)
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    for _, field in ipairs({ "admission_digest", "admission_receipt" }) do
      resolved_check = runtime_executor.resolve(value.request, value.ports)
      resolved_check[field] = nil
      rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    end
    resolved_check = runtime_executor.resolve(value.request, value.ports)
    resolved_check.selected_entrypoint.executor_id = nil
    rejects(function() contract.validate_resolved_invocation(resolved_check) end)
    bad = fixture({ change_documents=function(docs) docs.policy_ref.execution_profile = "other" end })
    rejects(function() runtime_executor.resolve(bad.request, bad.ports) end)
    bad = fixture(); bad.ports.now = function() return "not-time" end
    local resolved = runtime_executor.resolve(bad.request, bad.ports)
    rejects(function() executor.execute(resolved, bad.ports) end)
    bad = fixture()
    resolved = runtime_executor.resolve(bad.request, bad.ports)
    local valid_execution_sha256 = bad.ports.sha256
    bad.ports.sha256 = function(bytes)
      if type(bytes) == "string" and bytes:find(contract.schemas.admission_request, 1, true) then
        return valid_execution_sha256(bytes)
      end
      return "bad"
    end
    rejects(function() executor.execute(resolved, bad.ports) end)
  end,

  test_resolver_port_and_admission_failures_are_closed = function()
    local value = fixture()
    value.ports.load_immutable = function() error("boom") end
    expect_failure("port-failed", function() runtime_executor.resolve(value.request, value.ports) end)
    t.eq(#value.calls.admissions, 0)

    for _, invalid in ipairs({
      function() return nil end,
      function() return 42 end,
      function() return "" end,
    }) do
      value = fixture()
      value.ports.load_immutable = invalid
      expect_failure("immutable-load-failed", function() runtime_executor.resolve(value.request, value.ports) end)
      t.eq(#value.calls.admissions, 0)
    end

    value = fixture()
    value.ports.decode_json = function() return "scalar" end
    expect_failure("decode-failed", function() runtime_executor.resolve(value.request, value.ports) end)
    t.eq(#value.calls.admissions, 0)

    for _, invalid in ipairs({ false, "bad" }) do
      value = fixture()
      value.ports.admit_resolution = function() return invalid end
      expect_failure("port-failed", function() runtime_executor.resolve(value.request, value.ports) end)
      assert_zero_execution_effects(value)
    end
  end,

  test_missing_ports_fail_closed = function()
    local value = fixture()
    expect_failure("resolver ports must be a table", function() runtime_executor.resolve(value.request, nil) end)
    for _, name in ipairs({
      "load_immutable", "load_package_content", "sha256", "decode_json",
      "check_runtime_compatibility", "admit_resolution",
    }) do
      value = fixture()
      value.ports[name] = nil
      expect_failure(name .. " must be callable", function() runtime_executor.execute(value.request, value.ports) end)
      t.eq(#value.calls.loads, 0)
      assert_zero_execution_effects(value)
    end

    value = fixture()
    local resolved = runtime_executor.resolve(value.request, value.ports)
    value.ports.browser_read_title = nil
    expect_failure("browser_read_title must be callable", function() executor.execute(resolved, value.ports) end)
    t.eq(#value.calls.freshness, 0)
    t.eq(#value.calls.writes, 0)
  end,
}
