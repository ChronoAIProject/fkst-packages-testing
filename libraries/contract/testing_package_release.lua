local canonical_json = require("contract.canonical_json")
local error_facts = require("contract.error_facts")

local M = {}

local function fail(classification, message)
  error(error_facts.error_message("contract.testing-package-release", classification, message))
end

local function fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key in pairs(value) do if not allowed[key] then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end end
end

local function exact(value, expected, field)
  if value ~= expected then fail("identity-mismatch", field .. " must equal " .. expected) end
end

local function digest(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then fail("malformed-digest", field) end
end

local function commit(value, field)
  if type(value) ~= "string" or #value ~= 40 or value:match("^[0-9a-f]+$") == nil then fail("malformed-commit", field) end
end

local function file_binding(value, context, manifest)
  local allowed = { path=true, size_bytes=true, sha256=true }
  if manifest then allowed.manifest_digest = true end
  fields(value, allowed, context)
  if type(value.path) ~= "string" or value.path == "" or value.path:sub(1, 1) == "/" or value.path:find("\\", 1, true)
      or value.path:find("[%z\1-\31]") then fail("unsafe-path", context .. ".path") end
  for segment in value.path:gmatch("[^/]+") do if segment == "." or segment == ".." then fail("unsafe-path", context .. ".path") end end
  if value.path:find("//", 1, true) then fail("unsafe-path", context .. ".path") end
  if type(value.size_bytes) ~= "number" or value.size_bytes < 1 or value.size_bytes % 1 ~= 0 then fail("malformed-size", context .. ".size_bytes") end
  digest(value.sha256, context .. ".sha256")
  if manifest then digest(value.manifest_digest, context .. ".manifest_digest") end
end

function M.validate(value)
  fields(value, { schema=true,canonicalization=true,package=true,bundle=true,manifest=true,schema_catalog=true,
    schema_release=true,source=true,producer=true,runtime=true,executor=true,reducer=true,result_authority=true,
    mappings=true,creation_metadata=true }, "release")
  exact(value.schema, "testing-package-release.v1", "schema")
  exact(value.canonicalization, "fkst-testing-package-release-canonical-json.v1", "canonicalization")
  fields(value.package, { package_id=true,package_version=true,package_content_sha256=true,supported_profile=true,capability=true }, "package")
  exact(value.package.package_id, "testing-runner", "package.package_id")
  if type(value.package.package_version) ~= "string" or value.package.package_version:match("^[0-9]+%.[0-9]+%.[0-9]+$") == nil then fail("malformed-version", "package.package_version") end
  digest(value.package.package_content_sha256, "package.package_content_sha256")
  exact(value.package.supported_profile, "browser-deterministic.v1", "package.supported_profile")
  exact(value.package.capability, "browser.read-title.v1", "package.capability")
  file_binding(value.bundle, "bundle", false); file_binding(value.manifest, "manifest", true)
  file_binding(value.schema_catalog, "schema_catalog", false); file_binding(value.schema_release, "schema_release", false)
  fields(value.source, { repository_commit=true,fkst_packages_commit=true,fkst_substrate_commit=true }, "source")
  commit(value.source.repository_commit, "source.repository_commit"); commit(value.source.fkst_packages_commit, "source.fkst_packages_commit"); commit(value.source.fkst_substrate_commit, "source.fkst_substrate_commit")
  fields(value.producer, { name=true,version=true,generator=true,generator_version=true }, "producer")
  exact(value.producer.name, "fkst-packages-testing", "producer.name"); exact(value.producer.generator, "scripts/generate_testing_package_release.py", "producer.generator")
  fields(value.runtime, { lua=true,platform=true }, "runtime"); exact(value.runtime.lua, "5.4.0", "runtime.lua"); exact(value.runtime.platform, "linux-amd64", "runtime.platform")
  fields(value.executor, { module=true,["function"]=true,executor_id=true }, "executor")
  exact(value.executor.module, "testing_package_executor.executor", "executor.module"); exact(value.executor["function"], "execute", "executor.function"); exact(value.executor.executor_id, "testing-package-executor.browser-title.v1", "executor.executor_id")
  fields(value.reducer, { schema=true,reducer_id=true,reducer_version=true,reducer_sha256=true,policy_profile=true,supported_result_contract_majors=true }, "reducer")
  exact(value.reducer.schema, "testing-assertion-reducer-identity.v1", "reducer.schema"); exact(value.reducer.reducer_id, "testing.assertion-reducer.browser-title-equals", "reducer.reducer_id"); exact(value.reducer.reducer_version, "1.0.0", "reducer.reducer_version"); digest(value.reducer.reducer_sha256, "reducer.reducer_sha256"); exact(value.reducer.policy_profile, "browser-title-equals.v1", "reducer.policy_profile")
  if type(value.reducer.supported_result_contract_majors) ~= "table" or #value.reducer.supported_result_contract_majors ~= 1 then fail("mapping-mismatch", "reducer majors") end
  exact(value.reducer.supported_result_contract_majors[1], "testing-case-result-set.v2", "reducer major")
  fields(value.result_authority, { receipt_schema=true }, "result_authority"); exact(value.result_authority.receipt_schema, "testing-result-authority-receipt.v1", "result_authority.receipt_schema")
  if type(value.mappings) ~= "table" or #value.mappings ~= 1 then fail("mapping-mismatch", "mappings must contain exactly one entry") end
  fields(value.mappings[1], { entrypoint=true,contract_major=true,module=true,["function"]=true }, "mapping")
  exact(value.mappings[1].entrypoint, "testing-runner.run", "mapping.entrypoint"); exact(value.mappings[1].contract_major, "testing-runner.v1", "mapping.contract_major"); exact(value.mappings[1].module, "testing_package_executor.executor", "mapping.module"); exact(value.mappings[1]["function"], "execute", "mapping.function")
  fields(value.creation_metadata, { created_at=true,build_id=true }, "creation_metadata")
  exact(value.creation_metadata.created_at, "2026-09-04T00:00:00Z", "creation_metadata.created_at"); exact(value.creation_metadata.build_id, "testing-package-release-walking-skeleton-v1", "creation_metadata.build_id")
  return value
end

function M.canonicalize(value)
  M.validate(value)
  return canonical_json.encode(value) .. "\n"
end

return M
