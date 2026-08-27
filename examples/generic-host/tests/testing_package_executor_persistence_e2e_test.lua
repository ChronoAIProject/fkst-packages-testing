local package_manifest = require("contract.testing_package_manifest")
local testing_evidence_manifest = require("contract.testing_evidence_manifest")
local testing_results = require("contract.testing_results")
local runtime_executor = require("testing_runtime.testing_package_executor")
local runtime_json = require("testing_runtime.json")
local support = require("test_support.canonical_workflow_qa")
local t = fkst.test

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function fixture()
  local package_bytes = "testing-runner-1.0.0 admitted package bytes"
  local manifest = {
    schema="testing-package-manifest.v1", canonicalization="fkst-testing-package-manifest-canonical-json.v1",
    package_id="testing-runner", package_version="1.0.0", source_commit="0123456789abcdef0123456789abcdef01234567",
    package_content_sha256=support.sha256_bytes(package_bytes),
    supported_contracts={ majors={"testing-runner.v1"}, canonicalization_profiles={"fkst-testing-package-manifest-canonical-json.v1"} },
    entrypoints={ { name="testing-runner.run", contract_major="testing-runner.v1", capabilities={"browser.read-title.v1"} } },
    semantic_capabilities={"browser.read-title.v1"}, runtime_requirements={lua="5.4.0",platforms={"linux-amd64"}},
    dependencies={
      fkst_packages={id="fkst-packages",commit="abcdef0123456789abcdef0123456789abcdef01"},
      fkst_substrate={id="fkst-substrate",commit="fedcba9876543210fedcba9876543210fedcba98"},
    },
    producer={name="fkst-packages-testing",version="1.0.0",toolchain="walking-skeleton"},
    creation_metadata={created_at="2026-08-21T00:00:00Z",build_id="executor-walking-skeleton"},
  }
  manifest.manifest_digest = support.sha256_bytes(package_manifest.canonicalize(manifest))
  local docs = {
    package_manifest_ref=manifest,
    source_ref={schema="testing-package-source.v1",source_id="fixture-home",target_url="http://127.0.0.1:4173/"},
    plan_ref={schema="testing-package-plan.v1",case_id="case-home-title",assertion={assertion_id="assert-home-title",expected="Fixture Home",required=true,type="title-equals"}},
    pql_input_ref={schema="testing-package-pql-input.v1",requirement_id="REQ-HOME-TITLE"},
    policy_ref={schema="testing-package-policy.v1",execution_profile="browser-deterministic.v1",authorized_entrypoint="testing-runner.run",allowed_capabilities={"browser.read-title.v1"}},
    capability_set_ref={schema="testing-package-capability-set.v1",capabilities={"browser.read-title.v1"}},
  }
  local refs = {
    package_manifest_ref={kind="testing-package-manifest",ref="immutable://packages/testing-runner/1.0.0/manifest.json"},
    source_ref={kind="testing-package-source",ref="immutable://inputs/source.json"}, plan_ref={kind="testing-package-plan",ref="immutable://inputs/plan.json"},
    pql_input_ref={kind="testing-package-pql-input",ref="immutable://inputs/pql.json"}, policy_ref={kind="testing-package-policy",ref="immutable://inputs/policy.json"},
    capability_set_ref={kind="testing-package-capability-set",ref="immutable://inputs/capabilities.json"},
  }
  local storage, decoded, approved = {}, {}, {}
  for field, ref in pairs(refs) do
    local bytes = runtime_json.encode(docs[field])
    storage[ref.ref], decoded[bytes] = bytes, copy(docs[field])
    approved[field] = {kind=ref.kind,ref=ref.ref,sha256=support.sha256_bytes(bytes)}
  end
  return {
    request={schema="testing-package-executor.request.v1",executor={schema="testing-package-executor.identity.v1",package_id="testing-runner",package_version="1.0.0",package_content_sha256=manifest.package_content_sha256,manifest_digest=manifest.manifest_digest,entrypoint="testing-runner.run",contract_major="testing-runner.v1"},execution_profile="browser-deterministic.v1",approved_input_refs=approved,trace_id="trace-walking-skeleton",dedup_key="dedup-walking-skeleton"},
    resolver_ports={
      load_immutable=function(ref) return assert(storage[ref.ref]) end,
      load_package_content=function() return package_bytes end,
      decode_json=function(bytes) return copy(assert(decoded[bytes])) end,
      check_runtime_compatibility=function() return true end,
      admit_resolution=function(request) return {schema="testing-package-executor.admission-receipt.v1",status="admitted",admission_key=request.admission_key,admission_digest=request.admission_digest} end,
    },
  }
end

local function attach_resolver(host, value)
  for name, port in pairs(value.resolver_ports) do host[name] = port end
  host.sha256 = support.sha256_bytes
  return host
end

local function persisted_pair(host, completed)
  local manifest = assert(host.store:load(completed.evidence_manifest_ref.ref))
  local result_set = assert(host.store:load(completed.case_result_set_ref.ref))
  local manifest_context = #manifest.value.entries == 0 and { allow_empty_entries=true } or nil
  testing_results.validate_case_result_set(result_set.value, nil, manifest.value, support.sha256_bytes, manifest_context)
  testing_evidence_manifest.validate(manifest.value, result_set.value, support.sha256_bytes, manifest_context)
  return manifest.value, result_set.value
end

local function reset_run()
  support.remove_tree(".testing/runs/dedup-walking-skeleton", ".testing/runs/")
end

return {
  test_persists_and_replays_one_admitted_browser_title_result = function()
    reset_run()
    local server_script = "const http=require('http');const s=http.createServer((q,r)=>{r.writeHead(200,{'content-type':'text/html'});r.end('<title>Fixture Home</title>')});s.listen(4173,'127.0.0.1');"
    local pid = support.spawn_process({"node","-e",server_script}, ".", "/tmp/fkst-testing-package-executor-fixture")
    local ok, err = pcall(function()
      t.is_true(support.wait_http("http://127.0.0.1:4173/", 10))
      local fixture = fixture()
      local host = support.testing_package_executor_ports({
        browser_read_title=function(url)
          local response = support.http_request({url=url,method="GET"}, 10)
          t.eq(response.status, 200)
          return assert(response.body:match("<title>(.-)</title>"))
        end,
      })
      attach_resolver(host, fixture)

      local first = runtime_executor.execute(fixture.request, host)
      local manifest = assert(host.store:load(first.evidence_manifest_ref.ref))
      local result_set = assert(host.store:load(first.case_result_set_ref.ref))
      t.eq(manifest.digest, first.evidence_manifest_ref.sha256)
      t.eq(result_set.digest, first.case_result_set_ref.sha256)
      t.eq(manifest.value.canonical_sha256, first.evidence_manifest_sha256)
      testing_results.validate_case_result_set(result_set.value, nil, manifest.value, support.sha256_bytes)
      testing_evidence_manifest.validate(manifest.value, result_set.value, support.sha256_bytes)
      local replay = runtime_executor.execute(fixture.request, host)
      t.is_true(support.equal(replay, first))
      t.eq(host.counters.claims, 1); t.eq(host.counters.freshness, 1); t.eq(host.counters.browser, 1)
      t.eq(host.counters.intents, 1); t.eq(host.counters.receipts, 1); t.eq(host.counters.writes, 2)
      t.eq(host.counters.completions, 1); t.eq(host.counters.clock, 2)
      reset_run()
    end)
    support.direct_exec({"kill",tostring(pid)})
    support.remove_tree("/tmp/fkst-testing-package-executor-fixture", "/tmp/")
    if not ok then error(err, 0) end
  end,

  test_persists_unequal_and_lost_terminal_outcomes = function()
    reset_run()
    local unequal_fixture = fixture()
    local unequal_host = attach_resolver(support.testing_package_executor_ports({
      browser_read_title=function() return "Unexpected Home" end,
    }), unequal_fixture)
    local unequal = runtime_executor.execute(unequal_fixture.request, unequal_host)
    local _, unequal_result = persisted_pair(unequal_host, unequal)
    t.eq(unequal_result.cases[1].execution_status, "failed")
    t.eq(unequal_result.cases[1].classification, "assertion_failure")
    t.eq(unequal_result.cases[1].observations[1].value, "Unexpected Home")
    reset_run()

    local lost_fixture = fixture()
    local first_host = attach_resolver(support.testing_package_executor_ports({
      browser_read_title=function() error("lost recovery must not call Browser") end,
    }), lost_fixture)
    local resolved = runtime_executor.resolve(lost_fixture.request, first_host)
    t.is_true(first_host.persist_effect_intent({ schema="testing-package-executor.effect-intent.v1",
      dedup_key=resolved.dedup_key, admission_digest=resolved.admission_digest,
      claim_id="claim-dedup-walking-skeleton", effect_id="effect-case-home-title-title",
      url="http://127.0.0.1:4173/" }))
    local restarted = attach_resolver(support.testing_package_executor_ports({ store=first_host.store,
      browser_read_title=function() error("lost recovery must not call Browser") end,
    }), lost_fixture)
    local lost = runtime_executor.execute(lost_fixture.request, restarted)
    local lost_manifest, lost_result = persisted_pair(restarted, lost)
    t.eq(#lost_manifest.entries, 0)
    t.eq(lost_result.cases[1].execution_status, "lost")
    t.eq(lost_result.cases[1].non_execution_reason, "execution-lost-between-action-and-assertion")
    t.eq(restarted.counters.browser, 0); t.eq(restarted.counters.freshness, 0)
    reset_run()
  end,

  test_restart_and_acknowledgement_loss_do_not_repeat_browser_effects = function()
    reset_run()
    local value = fixture()
    local first = attach_resolver(support.testing_package_executor_ports({
      browser_read_title=function() return "Fixture Home" end,
    }), value)
    first.write_canonical = function() error("crash after receipt") end
    local ok = pcall(function() runtime_executor.execute(value.request, first) end)
    t.eq(ok, false); t.eq(first.counters.browser, 1); t.eq(first.counters.receipts, 1)
    local restarted = attach_resolver(support.testing_package_executor_ports({ store=first.store,
      browser_read_title=function() error("receipt recovery must not call Browser") end,
    }), value)
    local recovered = runtime_executor.execute(value.request, restarted)
    persisted_pair(restarted, recovered)
    t.eq(restarted.counters.browser, 0); t.eq(restarted.counters.intents, 0); t.eq(restarted.counters.receipts, 0)
    reset_run()

    local ack_value = fixture()
    local ack = { fired=false }
    local ack_first = attach_resolver(support.testing_package_executor_ports({ writer_ack_loss=ack,
      browser_read_title=function() return "Fixture Home" end,
    }), ack_value)
    ok = pcall(function() runtime_executor.execute(ack_value.request, ack_first) end)
    t.eq(ok, false); t.eq(ack_first.counters.browser, 1)
    local ack_restarted = attach_resolver(support.testing_package_executor_ports({ store=ack_first.store,
      browser_read_title=function() error("writer recovery must not call Browser") end,
    }), ack_value)
    local ack_completed = runtime_executor.execute(ack_value.request, ack_restarted)
    persisted_pair(ack_restarted, ack_completed)
    t.eq(ack_restarted.counters.browser, 0)
    reset_run()

    local completion_value = fixture()
    local completion_first = attach_resolver(support.testing_package_executor_ports({ completion_ack_loss=true,
      browser_read_title=function() return "Fixture Home" end,
    }), completion_value)
    ok = pcall(function() runtime_executor.execute(completion_value.request, completion_first) end)
    t.eq(ok, false)
    local completion_restarted = attach_resolver(support.testing_package_executor_ports({ store=completion_first.store,
      browser_read_title=function() error("completed replay must not call Browser") end,
    }), completion_value)
    local replay = runtime_executor.execute(completion_value.request, completion_restarted)
    t.eq(replay.status, "completed")
    t.eq(completion_restarted.counters.claims, 0); t.eq(completion_restarted.counters.browser, 0)
    t.eq(completion_restarted.counters.writes, 0); t.eq(completion_restarted.counters.completions, 0)
    reset_run()
  end,
}
