local package_manifest = require("contract.testing_package_manifest")
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

return {
  test_persists_and_replays_one_admitted_browser_title_result = function()
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
      for name, port in pairs(fixture.resolver_ports) do host[name] = port end
      host.sha256 = support.sha256_bytes

      local first = runtime_executor.execute(fixture.request, host)
      local manifest = assert(host.store:load(first.evidence_manifest_ref.ref))
      local result_set = assert(host.store:load(first.case_result_set_ref.ref))
      t.eq(manifest.digest, first.evidence_manifest_ref.sha256)
      t.eq(result_set.digest, first.case_result_set_ref.sha256)
      local replay = runtime_executor.execute(fixture.request, host)
      t.is_true(support.equal(replay, first))
      t.eq(host.counters.claims, 1); t.eq(host.counters.freshness, 1); t.eq(host.counters.browser, 1)
      t.eq(host.counters.intents, 1); t.eq(host.counters.receipts, 1); t.eq(host.counters.writes, 2)
      t.eq(host.counters.completions, 1); t.eq(host.counters.clock, 2)
    end)
    support.direct_exec({"kill",tostring(pid)})
    support.remove_tree("/tmp/fkst-testing-package-executor-fixture", "/tmp/")
    if not ok then error(err, 0) end
  end,
}
