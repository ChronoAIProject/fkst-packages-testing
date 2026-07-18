local contract = require("contract.environment_factory")
local core = require("core")
local graph = require("testkit.graph")
local hermetic_listener_host = require("tests.hermetic_listener_helpers")
local json_codec = require("testing_runtime.json")
local project_profile = require("contract.project_profile")
local runtime = require("runtime")
local t = fkst.test

local fixture_root = "packages/environment-factory/tests/fixtures/runtime/source"
local command_sequence = 0

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_host_file(path)
  local handle = io.open(path, "r")
  if handle == nil then return "" end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_host_file(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

local project_root

local function direct_exec_argv(request)
  local argv = type(request) == "table" and request.argv or nil
  if type(argv) ~= "table" or #argv == 0 then error("hermetic exec requires argv") end
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local command = table.concat(rendered, " ")
  if request.cwd ~= nil then command = "cd " .. shell_quote(request.cwd) .. " && " .. command end

  command_sequence = command_sequence + 1
  local stdout_path = os.tmpname() .. "-environment-stdout-" .. command_sequence
  local stderr_path = os.tmpname() .. "-environment-stderr-" .. command_sequence
  local ok, _, code = os.execute(command .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local stdout = read_host_file(stdout_path)
  local stderr = read_host_file(stderr_path)
  os.remove(stdout_path)
  os.remove(stderr_path)
  return {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = stdout,
    stderr = stderr,
  }
end

-- Package-test exec_argv is intentionally mock-only. This test-host adapter keeps the
-- production effect protocol but delegates inherited listener execution to the claim broker.
local function real_exec_argv(request)
  if request.listener_mode ~= "fkst-inherited-listeners-v1" then return direct_exec_argv(request) end
  local inherited = request.inherited_listeners
  local claim = type(inherited) == "table" and inherited.claim or nil
  if type(claim) ~= "table" or type(claim.broker_root) ~= "string" then
    error("hermetic inherited listener claim is missing")
  end
  local root = claim.broker_root
  local stdout_path = root .. "/runtime-stdout"
  local stderr_path = root .. "/runtime-stderr"
  write_host_file(root .. "/command.json", json_codec.encode({
    argv = request.argv,
    cwd = project_root,
    names = inherited.names,
    stdout_path = project_root .. "/" .. stdout_path,
    stderr_path = project_root .. "/" .. stderr_path,
    timeout_seconds = request.timeout or 30,
  }) .. "\n")
  local wait_script = table.concat({
    "const fs=require('fs');const root=process.argv[1];const end=Date.now()+Number(process.argv[2])*1000;",
    "(function wait(){if(fs.existsSync(root+'/response.json'))return process.exit(0);",
    "if(fs.existsSync(root+'/error.json'))return process.exit(47);",
    "if(Date.now()>=end)return process.exit(48);setTimeout(wait,10)})()",
  })
  local waited = direct_exec_argv({
    argv = { "node", "-e", wait_script, root, tostring((request.timeout or 30) + 2) },
    cwd = project_root,
  })
  if waited.exit_code ~= 0 then
    return { exit_code = waited.exit_code, stdout = "", stderr = read_host_file(root .. "/error.json") }
  end
  local response = json.decode(read_host_file(root .. "/response.json"))
  return {
    exit_code = response.exit_code,
    timed_out = response.timed_out,
    stdout = read_host_file(stdout_path),
    stderr = read_host_file(stderr_path),
  }
end

local function run_argv(argv, cwd, timeout)
  local result = real_exec_argv({ argv = argv, cwd = cwd, timeout = timeout or 20 })
  if result.exit_code ~= 0 then
    error("environment hermetic setup failed: " .. tostring(argv[1]) .. " exit=" .. tostring(result.exit_code)
      .. " stderr=" .. tostring(result.stderr), 0)
  end
  return tostring(result.stdout or "")
end

project_root = run_argv({ "node", "-e", "process.stdout.write(process.cwd())" }):gsub("%s+$", "")

local function make_context(suffix)
  local operation_id = "environment-hermetic-" .. suffix
  local artifact_root = ".testing/runs/" .. operation_id
  local host_root = ".testing/host/environment-factory/" .. operation_id
  return {
    operation_id = operation_id,
    artifact_root = artifact_root,
    source_root = artifact_root .. "/source",
    host_root = host_root,
    evidence_root = project_root .. "/" .. host_root .. "/cleanup-evidence",
    runtime_config_ref = { kind = "artifact", ref = host_root .. "/runtime-config.json" },
  }
end

local function write_json(path, value)
  file.write(path, json_codec.encode(value) .. "\n")
end

local function reserve_distinct_ports(count)
  local script = table.concat({
    "const net=require('net');",
    "const count=Number(process.argv[1]);",
    "const servers=[];const ports=[];",
    "function reserve(){",
    "if(servers.length===count){",
    "process.stdout.write(JSON.stringify(ports));",
    "let pending=servers.length;for(const server of servers)server.close(()=>{if(--pending===0)process.exit(0)});return;}",
    "const server=net.createServer();server.once('error',()=>process.exit(44));",
    "server.listen(0,'127.0.0.1',()=>{servers.push(server);ports.push(server.address().port);reserve();});",
    "}",
    "reserve();",
  })
  local ports = json.decode(run_argv({ "node", "-e", script, tostring(count) }))
  t.eq(#ports, count)
  local seen = {}
  for _, port in ipairs(ports) do
    t.is_true(type(port) == "number" and port >= 1 and port <= 65535)
    t.eq(seen[port], nil)
    seen[port] = true
  end
  return {
    application = ports[1],
    database = ports[2],
    middleware = ports[3],
  }
end

local function assert_listener_released(port)
  local script = table.concat({
    "const net=require('net');",
    "const socket=net.connect({host:'127.0.0.1',port:Number(process.argv[1])});",
    "socket.once('connect',()=>{socket.destroy();process.exit(41);});",
    "socket.once('error',()=>process.exit(0));",
    "setTimeout(()=>{socket.destroy();process.exit(42);},1500);",
  })
  run_argv({ "node", "-e", script, tostring(port) }, nil, 5)
end

local function assert_path_absent(path)
  run_argv({
    "node",
    "-e",
    "if(require('fs').existsSync(process.argv[1])) process.exit(43)",
    path,
  }, nil, 5)
end

local function http_json(port, path)
  local script = table.concat({
    "const http=require('http');",
    "const req=http.get({host:'127.0.0.1',port:Number(process.argv[1]),path:process.argv[2],timeout:1500},res=>{",
    "let body='';res.setEncoding('utf8');res.on('data',chunk=>body+=chunk);",
    "res.on('end',()=>process.stdout.write(JSON.stringify({status:res.statusCode,body,json:JSON.parse(body)})));",
    "});req.once('timeout',()=>req.destroy(new Error('timeout')));req.once('error',()=>process.exit(45));",
  })
  return json.decode(run_argv({ "node", "-e", script, tostring(port), path }, nil, 5))
end

local function http_text(port, path)
  local script = table.concat({
    "const http=require('http');",
    "const req=http.get({host:'127.0.0.1',port:Number(process.argv[1]),path:process.argv[2],timeout:1500},res=>{",
    "let body='';res.setEncoding('utf8');res.on('data',chunk=>body+=chunk);",
    "res.on('end',()=>process.stdout.write(JSON.stringify({status:res.statusCode,body})));",
    "});req.once('timeout',()=>req.destroy(new Error('timeout')));req.once('error',()=>process.exit(45));",
  })
  return json.decode(run_argv({ "node", "-e", script, tostring(port), path }, nil, 5))
end

local function exact_authority(approval_digest, authority_ref, evidence_ref)
  return {
    source_ref = authority_ref,
    policy_revision = "environment-runtime-policy-1",
    approval_sha256 = approval_digest,
    evidence_ref = evidence_ref,
    authenticated = true,
  }
end

local function request_fixture(ctx, ports, commit_sha)
  local repository = {
    url = "https://example.invalid/fkst/environment-runtime-fixture.git",
    commit_sha = commit_sha,
  }
  local authorization_root = ctx.host_root .. "/authorization"
  local profile_ref = { kind = "artifact", ref = authorization_root .. "/profile.json" }
  local approval_ref = { kind = "artifact", ref = authorization_root .. "/approval.json" }
  local receipt_ref = { kind = "artifact", ref = authorization_root .. "/validation-receipt.json" }
  local authority_ref = { kind = "host-policy", ref = "fixtures/environment-runtime" }
  local evidence_ref = { kind = "signed-attestation", ref = "fixtures/environment-runtime-approval" }
  local profile = {
    schema = project_profile.schemas.profile,
    revision = "environment-runtime-profile-1",
    repository = repository,
    working_directory = ".",
    commands = {
      install = { "npm", "ci", "--offline", "--ignore-scripts" },
      build = { "node", "phase.js", "build" },
      migrate = { "node", "phase.js", "migrate", tostring(ports.database) },
      seed = { "node", "phase.js", "seed", tostring(ports.database) },
      start = { "node", "app.js", tostring(ports.middleware) },
      cleanup = { "node", "phase.js", "cleanup", "application" },
    },
    application_listener_mode = "fkst-inherited-listeners-v1",
    dependent_services = {
      {
        name = "database",
        listener_mode = "fkst-inherited-listeners-v1",
        start_argv = { "python3", "database_service.py" },
        cleanup_argv = { "node", "phase.js", "cleanup", "database" },
        readiness_checks = { { type = "tcp", host = "127.0.0.1", port = ports.database } },
      },
      {
        name = "middleware",
        listener_mode = "fkst-inherited-listeners-v1",
        start_argv = { "node", "middleware.js", tostring(ports.database) },
        cleanup_argv = { "node", "phase.js", "cleanup", "middleware" },
        readiness_checks = { { type = "tcp", host = "127.0.0.1", port = ports.middleware } },
      },
    },
    readiness_checks = {
      { type = "http", url = "http://127.0.0.1:" .. tostring(ports.application) .. "/health", expected_status = 200 },
      { type = "argv", argv = { "node", "phase.js", "verify", tostring(ports.middleware) } },
    },
    allowed_origins = { "http://127.0.0.1:" .. tostring(ports.application) },
    mutation_policy = { mode = "read-only" },
    timeouts = {
      install_seconds = 15,
      build_seconds = 5,
      migrate_seconds = 5,
      seed_seconds = 5,
      start_seconds = 5,
      readiness_seconds = 10,
      cleanup_seconds = 5,
      total_seconds = 120,
      receipt_ttl_seconds = 120,
    },
    resource_budgets = {
      cpu_millis = 64000,
      memory_mb = 512,
      disk_mb = 256,
      processes = 8,
      network_requests = 30,
      output_bytes = 32768,
    },
  }

  local runtime_config = {
    schema = "environment-factory.runtime-config.v1",
    revision = "environment-runtime-config-1",
    state_auth_key = "environment-runtime-test-state-auth-key-2026",
    state_auth_key_revision = "environment-runtime-test-key-1",
    now = "2026-07-16T00:00:30Z",
    trusted_authorities = {},
    repository_mirrors = { [repository.url] = ctx.source_root },
    command_environment = {
      FKST_FIXTURE_EVIDENCE_DIR = ctx.evidence_root,
    },
    authorization_sources = {
      { source_ref = profile_ref, artifact_ref = profile_ref },
      { source_ref = approval_ref, artifact_ref = approval_ref },
      { source_ref = receipt_ref, artifact_ref = receipt_ref },
    },
    frozen_dependency_policy = {
      kind = "npm-ci-offline-v1",
      revision = "environment-runtime-npm-policy-1",
      manifest_path = "package.json",
      lockfile_path = "package-lock.json",
      argv = profile.commands.install,
    },
  }
  write_json(ctx.runtime_config_ref.ref, runtime_config)

  local function sha256(value)
    return runtime.call_cli("sha256", { artifact_root = ctx.artifact_root, value = value }, 15).digest
  end

  local approval = {
    schema = project_profile.schemas.approval,
    approval_id = ctx.operation_id .. "-approval",
    canonicalization = project_profile.canonicalization,
    profile_sha256 = project_profile.profile_sha256(profile, sha256),
    repository = repository,
    authority = authority_ref,
    policy_revision = "environment-runtime-policy-1",
    evidence_ref = evidence_ref,
    issued_at = "2026-07-16T00:00:00Z",
    expires_at = "2026-07-16T01:00:00Z",
    max_uses = 1,
    trace_id = "trace-" .. ctx.operation_id,
    dedup_key = ctx.operation_id,
  }
  local approval_digest = project_profile.approval_sha256(approval, sha256)
  local trusted = {
    source_ref = authority_ref,
    policy_revision = approval.policy_revision,
    verify = function(attestation_request)
      return {
        authenticated = true,
        approval_sha256 = attestation_request.approval_sha256,
        authority = attestation_request.approval.authority,
        policy_revision = attestation_request.approval.policy_revision,
        evidence_ref = attestation_request.approval.evidence_ref,
      }
    end,
  }
  local validation_receipt = project_profile.issue_validation_receipt(profile, approval, {
    now = runtime_config.now,
    sha256 = sha256,
    trusted_authorities = { trusted },
    approval_ref = approval_ref,
  })

  runtime_config.trusted_authorities = {
    exact_authority(approval_digest, authority_ref, evidence_ref),
  }
  write_json(ctx.runtime_config_ref.ref, runtime_config)
  write_json(profile_ref.ref, profile)
  write_json(approval_ref.ref, approval)
  write_json(receipt_ref.ref, validation_receipt)

  return {
    schema = contract.schemas.start,
    operation_id = ctx.operation_id,
    repository = repository,
    profile_ref = profile_ref,
    approval_ref = approval_ref,
    validation_receipt_ref = receipt_ref,
    operation_state_ref = { kind = "artifact", ref = ctx.artifact_root .. "/operation-state.json" },
    artifact_root = ctx.artifact_root,
    base_url = "http://127.0.0.1:" .. tostring(ports.application) .. "/health",
    runtime_ports = {
      { name = "application", port = ports.application },
      { name = "database", port = ports.database },
      { name = "middleware", port = ports.middleware },
    },
    sessions = { { role = "browser", browser_harness_command = "node" } },
    testing = {
      module = "environment-runtime-module",
      artifact_root = ctx.artifact_root .. "/testing",
      mutation_policy = "read-only",
    },
    trace_id = approval.trace_id,
    dedup_key = approval.dedup_key,
  }
end

local function initialize_repository(ctx)
  run_argv({
    "node",
    "-e",
    "const fs=require('fs');for(const value of process.argv.slice(1))fs.mkdirSync(value,{recursive:true});",
    ctx.source_root,
    ctx.artifact_root .. "/runtime-io",
    ctx.artifact_root .. "/diagnostics",
    ctx.artifact_root .. "/readiness-attempts",
    ctx.artifact_root .. "/testing",
    ctx.host_root,
    ctx.host_root .. "/authorization",
    ctx.host_root .. "/cleanup-evidence",
  }, nil, 5)
  run_argv({
    "node",
    "-e",
    "const fs=require('fs'),p=require('path');for(const name of fs.readdirSync(process.argv[1]))fs.cpSync(p.join(process.argv[1],name),p.join(process.argv[2],name),{recursive:true});",
    fixture_root,
    ctx.source_root,
  }, nil, 5)
  run_argv({ "git", "init", "--quiet" }, ctx.source_root)
  run_argv({ "git", "config", "user.email", "fixture@example.invalid" }, ctx.source_root)
  run_argv({ "git", "config", "user.name", "Environment Runtime Fixture" }, ctx.source_root)
  run_argv({ "git", "add", "." }, ctx.source_root)
  run_argv({ "git", "commit", "--quiet", "-m", "environment runtime fixture" }, ctx.source_root)
  local commit_sha = run_argv({ "git", "rev-parse", "HEAD" }, ctx.source_root):match("([0-9a-f]+)")
  t.is_true(type(commit_sha) == "string" and #commit_sha == 40)
  return commit_sha
end

local function cleanup_fixture(ctx)
  run_argv({
    "node",
    "-e",
    "const fs=require('fs');for(const value of process.argv.slice(1))fs.rmSync(value,{recursive:true,force:true});",
    ctx.artifact_root,
    ctx.host_root,
  }, nil, 10)
end

local function termination_request(request, interruption)
  return {
    schema = interruption == nil and contract.schemas.finalize or contract.schemas.interrupt,
    operation_id = request.operation_id,
    cleanup_ref = { kind = "environment-cleanup", ref = request.operation_id },
    operation_state_ref = request.operation_state_ref,
    interruption = interruption,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

local function start_ready(request)
  local ready = core.start(request)
  if ready.status ~= "ready" then
    local diagnostics = {}
    for _, ref in ipairs(ready.diagnostic_refs or {}) do
      local read_ok, body = pcall(file.read, ref.ref)
      if read_ok then table.insert(diagnostics, tostring(body)) end
    end
    error("real environment provisioning blocked class=" .. tostring(ready.failure_class)
      .. " diagnostics=" .. table.concat(diagnostics, " | "))
  end
  return ready
end

local function workspace_path(ctx)
  local operation_digest = runtime.call_cli("sha256", {
    artifact_root = ctx.artifact_root,
    value = ctx.operation_id,
  }, 15).digest
  return os.getenv("FKST_RUNTIME_ROOT") .. "/environment-factory/"
    .. operation_digest:sub(1, 24) .. "/checkout", operation_digest
end

local function diagnostic(outcome)
  return json.decode(file.read(outcome.diagnostic_ref.ref))
end

local function resource_record(ctx, cleanup_ref)
  local digest = runtime.call_cli("sha256", {
    artifact_root = ctx.artifact_root,
    value = cleanup_ref.ref,
  }, 15).digest
  local path = os.getenv("FKST_DURABLE_ROOT") .. "/environment-factory/resources/" .. digest .. ".json"
  return json.decode(read_host_file(path))
end

local function application_cleanup_ref(state)
  for _, resource in ipairs(state.resources) do
    if resource.id == "application" then return resource.cleanup_ref end
  end
  error("application cleanup ref is missing")
end

local function assert_frozen_dependency_proof(ready_receipt)
  local frozen_proof
  local diagnostic_bodies = {}
  for _, ref in ipairs(ready_receipt.diagnostic_refs) do
    local read_ok, body = pcall(file.read, ref.ref)
    if read_ok then table.insert(diagnostic_bodies, body) end
    local decoded_ok, item = pcall(function() return json.decode(body) end)
    if decoded_ok and item ~= nil and type(item.frozen_dependency_proof) == "table" then
      local proof = item.frozen_dependency_proof
      frozen_proof = {
        policy_revision = proof.policy_revision,
        lockfile_sha256_before = proof.lockfile_sha256_before,
        lockfile_sha256_after = proof.lockfile_sha256_after,
        manifest_sha256_before = proof.manifest_sha256_before,
        manifest_sha256_after = proof.manifest_sha256_after,
      }
    end
  end
  t.is_true(frozen_proof ~= nil, table.concat(diagnostic_bodies, " | "))
  t.eq(frozen_proof.policy_revision, "environment-runtime-npm-policy-1")
  t.eq(frozen_proof.lockfile_sha256_before, frozen_proof.lockfile_sha256_after)
  t.eq(frozen_proof.manifest_sha256_before, frozen_proof.manifest_sha256_after)
end

local function assert_cleanup_evidence(ctx, optional)
  local expected = {
    "application-cleanup-command.json",
    "application-stopped.json",
    "middleware-cleanup-command.json",
    "middleware-stopped.json",
    "database-cleanup-command.json",
    "database-stopped.json",
  }
  for _, name in ipairs(expected) do
    local body = read_host_file(ctx.evidence_root .. "/" .. name)
    if not (type(optional) == "table" and optional[name] == true) then
      t.is_true(#body > 0, "missing cleanup evidence " .. name)
      local decoded_ok = pcall(function() return json.decode(body) end)
      t.is_true(decoded_ok)
    end
  end
end

local function finalize_ready(ctx, request, ready, ports, optional_evidence)
  local final_result = core.finalize(termination_request(request))
  if final_result.status ~= "finalized" then
    local details = {}
    for _, ref in ipairs(final_result.diagnostic_refs or {}) do
      local read_ok, body = pcall(file.read, ref.ref)
      if read_ok then table.insert(details, tostring(body)) end
    end
    error("finalization blocked diagnostics=" .. table.concat(details, " | "))
  end
  t.eq(final_result.cleanup_status, "complete")
  t.is_true(#file.read(final_result.environment_receipt_ref.ref) > 0)
  assert_cleanup_evidence(ctx, optional_evidence)
  for _, port in pairs(ports) do assert_listener_released(port) end
  return final_result
end

local hermetic_lock_path = ".testing/host/environment-factory/hermetic-test.lock"

local function acquire_hermetic_lock()
  local script = table.concat({
    "const fs=require('fs');const path=process.argv[1];const end=Date.now()+120000;",
    "fs.mkdirSync(require('path').dirname(path),{recursive:true});",
    "(function lock(){try{fs.mkdirSync(path);process.exit(0)}catch(e){",
    "if(e.code!=='EEXIST'||Date.now()>=end)process.exit(52);setTimeout(lock,20)}})()",
  })
  run_argv({ "node", "-e", script, hermetic_lock_path }, project_root, 125)
end

local function release_hermetic_lock()
  run_argv({
    "node", "-e", "require('fs').rmSync(process.argv[1],{recursive:true,force:true})",
    hermetic_lock_path,
  }, project_root, 5)
end

local function with_fixture(suffix, body)
  acquire_hermetic_lock()
  local ctx = make_context(suffix)
  cleanup_fixture(ctx)
  local previous_exec_argv = rawget(_G, "exec_argv")
  local previous_network_listener = rawget(_G, "network_listener")
  local previous_runtime_config_ref = rawget(_G, "environment_factory_runtime_config_ref")
  rawset(_G, "exec_argv", real_exec_argv)
  rawset(_G, "network_listener", hermetic_listener_host.new({ host_root = ctx.host_root,
    project_root = project_root, read_file = read_host_file, run_argv = run_argv,
    write_file = write_host_file }))
  rawset(_G, "environment_factory_runtime_config_ref", ctx.runtime_config_ref)
  local request
  local finalized = false
  local ok, failure = pcall(function()
    local ports = reserve_distinct_ports(3)
    local commit_sha = initialize_repository(ctx)
    request = request_fixture(ctx, ports, commit_sha)
    body(ctx, request, ports, commit_sha, function() finalized = true end)
  end)

  if not ok and request ~= nil and not finalized then
    pcall(core.interrupt, termination_request(request, "interrupted"))
  end
  rawset(_G, "environment_factory_runtime_config_ref", previous_runtime_config_ref)
  rawset(_G, "network_listener", previous_network_listener)
  rawset(_G, "exec_argv", previous_exec_argv)
  cleanup_fixture(ctx)
  release_hermetic_lock()
  if not ok then error(failure, 0) end
end

return {
  test_real_hermetic_runtime_keeps_all_processes_live_until_finalize = function()
    with_fixture("happy", function(ctx, request, ports, commit_sha, mark_finalized)
      local ready = start_ready(request)
      t.eq(ready.base_url, request.base_url)
      t.eq(ready.cleanup_status, "pending")
      t.eq(ready.trace_id, request.trace_id)
      t.eq(ready.dedup_key, request.dedup_key)
      t.eq(ready.sessions[1].browser_harness_command, "node")
      t.is_true(type(ready.readiness_correlation.attempt_id) == "string")

      local database_state = http_json(ports.database, "/state")
      t.eq(database_state.status, 200)
      t.eq(database_state.json.migrated, true)
      t.eq(database_state.json.seeded, true)
      t.eq(database_state.json.row_count, 1)
      t.eq(database_state.json.message, "seeded-through-sql")
      local middleware_state = http_json(ports.middleware, "/state")
      t.eq(middleware_state.status, 200)
      t.eq(middleware_state.json.via, "middleware")
      t.eq(middleware_state.json.protocol_package, "fixture-protocol")
      local application_health = http_text(ports.application, "/health")
      t.eq(application_health.status, 200)
      t.eq(application_health.body, "ready\n")

      local ready_receipt_body = file.read(ready.environment_receipt_ref.ref)
      local ready_receipt = json.decode(ready_receipt_body)
      t.eq(ready_receipt.status, "ready")
      t.eq(ready_receipt.repository.resolved_commit, commit_sha)
      t.eq(ready_receipt.cleanup_status, "pending")
      t.is_true(#ready_receipt.diagnostic_refs > 0)
      assert_frozen_dependency_proof(ready_receipt)

      local checkout_path = workspace_path(ctx)
      t.is_true(#read_host_file(checkout_path .. "/node_modules/fixture-protocol/index.js") > 0)
      t.eq(
        read_host_file(checkout_path .. "/node_modules/fixture-protocol/index.js"),
        read_host_file(checkout_path .. "/vendor/protocol/index.js")
      )

      local readiness_check = core.browser_readiness_check(ready, {
        operation_state_ref = request.operation_state_ref,
      })
      readiness_check.source_ref = {
        kind = "artifact",
        ref = request.artifact_root .. "/browser-readiness-input.json",
      }
      local readiness_trace = graph.run({
        queue = "browser-readiness.browser_readiness_check",
        source_ref = { kind = "external", reference = "environment-hermetic-readiness" },
        payload = readiness_check,
      }, { max_steps = 2 })
      graph.assert_covers(readiness_trace, {
        "browser-readiness.browser_readiness_check -> browser-readiness.check_readiness",
      })
      local browser_result = graph.require_raise(
        readiness_trace,
        "browser-readiness.browser_readiness_result"
      ).payload
      t.eq(browser_result.status, "ready")
      browser_result.source_ref = copy(request.operation_state_ref)

      local handoff = core.handle_browser_readiness(browser_result)
      t.eq(handoff.module_start.schema, "testing-pipeline.module-start.v1")
      t.eq(handoff.module_start.module, request.testing.module)
      t.eq(handoff.module_start.preflight_result.status, "ready")
      t.eq(handoff.module_start.source_ref.ref, ready.environment_receipt_ref.ref)

      local pipeline_input = copy(handoff.module_start)
      pipeline_input.source_ref = {
        kind = "artifact",
        ref = request.artifact_root .. "/testing/pipeline-input.json",
      }
      local pipeline_trace = graph.run({
        queue = "testing-pipeline.module_start",
        source_ref = { kind = "external", reference = "environment-hermetic-pipeline" },
        payload = pipeline_input,
      }, { max_steps = 32 })
      graph.assert_covers(pipeline_trace, {
        "testing-pipeline.module_start -> testing-pipeline.start_module",
      })
      local module_loop = graph.require_raise(
        pipeline_trace,
        "module-test-loop.module_loop_request"
      ).payload
      t.eq(module_loop.module, request.testing.module)
      t.eq(module_loop.preflight_result.status, "ready")

      local publication = graph.require_raise(
        pipeline_trace,
        "test-publication.publication_request"
      ).payload
      t.eq(publication.schema, "test-publication.publication-request.v1")
      t.eq(publication.source_ref.ref, pipeline_input.source_ref.ref)
      publication.source_ref = copy(ready.environment_receipt_ref)
      local terminal_ack = core.acknowledge_testing_terminal(publication)
      t.eq(terminal_ack.acknowledged, true)
      local acknowledged_replay = core.handle_browser_readiness(browser_result)
      t.eq(acknowledged_replay.acknowledged, true)
      t.eq(acknowledged_replay.module_start, nil)

      local state_before = runtime.production().load_state(request.operation_state_ref)
      t.eq(state_before.authenticated, true)
      t.eq(state_before.state.status, "ready")
      for _, resource in ipairs(state_before.state.resources) do
        if resource.kind == "application" or resource.kind == "service" then
          t.eq(resource.cleaned == true, false)
        end
      end

      local frozen_request = {
        operation_id = request.operation_id,
        artifact_root = request.artifact_root,
        workspace_ref = state_before.state.workspace_ref,
        working_directory = ".",
        mode = "oneshot",
        requires_frozen_dependencies = true,
        resource_budgets = state_before.state.profile_snapshot.resource_budgets,
        output_bytes = state_before.state.profile_snapshot.resource_budgets.output_bytes,
        timeout_seconds = 15,
      }
      local wrong_argv = copy(frozen_request)
      wrong_argv.effect_id = request.dedup_key .. "/environment-factory/phase/install-wrong-argv"
      wrong_argv.argv = { "npm", "install" }
      local wrong_outcome = runtime.production().run_argv(wrong_argv)
      t.eq(wrong_outcome.status, "blocked")
      t.eq(wrong_outcome.frozen_dependencies_enforced, false)

      local lock_path = checkout_path .. "/package-lock.json"
      local lock_body = read_host_file(lock_path)
      os.remove(lock_path)
      local missing_lock = copy(frozen_request)
      missing_lock.effect_id = request.dedup_key .. "/environment-factory/phase/install-missing-lock"
      missing_lock.argv = { "npm", "ci", "--offline", "--ignore-scripts" }
      local missing_outcome = runtime.production().run_argv(missing_lock)
      write_host_file(lock_path, lock_body)
      t.eq(missing_outcome.status, "blocked")
      t.eq(missing_outcome.frozen_dependencies_enforced, false)

      local final_result = finalize_ready(ctx, request, ready, ports)
      mark_finalized()
      t.eq(file.read(ready.environment_receipt_ref.ref), ready_receipt_body)
      assert_path_absent(checkout_path)
      t.eq(run_argv({ "git", "status", "--porcelain" }, ctx.source_root), "")

      local _, operation_digest = workspace_path(ctx)
      for _, port in pairs(ports) do
        local port_digest = runtime.call_cli("sha256", {
          artifact_root = ctx.artifact_root,
          value = tostring(port),
        }, 15).digest
        assert_path_absent(os.getenv("FKST_DURABLE_ROOT") .. "/environment-factory/ports/" .. port_digest .. ".json")
      end
      t.is_true(#operation_digest == 64)

      local state_after = runtime.production().load_state(request.operation_state_ref)
      t.eq(state_after.authenticated, true)
      t.eq(state_after.state.status, "finalized")
      t.eq(state_after.state.cleanup_status, "complete")

      local overwrite_ok = pcall(runtime.production().write_receipt, {
        effect_id = request.dedup_key .. "/environment-factory/receipt/overwrite-attempt",
        operation_id = request.operation_id,
        artifact_root = request.artifact_root,
        receipt_ref = ready.environment_receipt_ref,
        receipt = { schema = contract.schemas.receipt, status = "forged" },
        timeout_seconds = 5,
      })
      t.eq(overwrite_ok, false)
      t.eq(file.read(ready.environment_receipt_ref.ref), ready_receipt_body)

      local forged_envelope = json.decode(file.read(request.operation_state_ref.ref))
      forged_envelope.state.status = "forged"
      file.write(request.operation_state_ref.ref, json_codec.encode(forged_envelope) .. "\n")
      local forged_state = runtime.production().load_state(request.operation_state_ref)
      t.eq(forged_state.authenticated, false)
      t.eq(final_result.status, "finalized")
    end)
  end,

  test_resource_budget_faults_are_isolated_from_happy_path_cleanup = function()
    with_fixture("budgets", function(ctx, request, ports, _, mark_finalized)
      local ready = start_ready(request)
      local state_before = runtime.production().load_state(request.operation_state_ref)
      local runtime_ports = runtime.production()
      local app_cleanup_ref = application_cleanup_ref(state_before.state)
      local _, operation_digest = workspace_path(ctx)
      local usage_path = os.getenv("FKST_DURABLE_ROOT") .. "/environment-factory/usage/"
        .. operation_digest .. ".json"
      local usage_before_zero = json.decode(read_host_file(usage_path))
      t.is_true(usage_before_zero.network_requests >= 3)

      local zero_budget = copy(state_before.state.profile_snapshot.resource_budgets)
      zero_budget.network_requests = 0
      local zero_probe = runtime_ports.wait_readiness({
        effect_id = request.dedup_key .. "/environment-factory/readiness/network-zero",
        operation_id = request.operation_id,
        artifact_root = request.artifact_root,
        workspace_ref = state_before.state.workspace_ref,
        working_directory = ".",
        checks = { { type = "http", url = request.base_url, expected_status = 200 } },
        runtime_ports = { { name = "application", port = ports.application } },
        process_cleanup_ref = app_cleanup_ref,
        resource_budgets = zero_budget,
        output_bytes = zero_budget.output_bytes,
        timeout_seconds = 2,
      })
      t.eq(zero_probe.status, "blocked")
      t.eq(diagnostic(zero_probe).reason, "network-request-budget-exceeded")
      t.eq(diagnostic(zero_probe).attempts, 0)
      t.eq(diagnostic(zero_probe).network_requests, 0)
      t.eq(json.decode(read_host_file(usage_path)).network_requests, usage_before_zero.network_requests)

      local checkout_path = workspace_path(ctx)
      local function budget_outcome(label, argv, changes)
        local budgets = copy(state_before.state.profile_snapshot.resource_budgets)
        for key, value in pairs(changes) do budgets[key] = value end
        return runtime_ports.run_argv({
          effect_id = request.dedup_key .. "/environment-factory/budget/" .. label,
          operation_id = request.operation_id .. "-budget-" .. label,
          artifact_root = request.artifact_root,
          workspace_ref = state_before.state.workspace_ref,
          working_directory = ".",
          argv = argv,
          mode = "oneshot",
          resource_budgets = budgets,
          output_bytes = budgets.output_bytes,
          timeout_seconds = 5,
        })
      end
      local cpu_blocked = budget_outcome("cpu", {
        "node", "-e", "const end=Date.now()+400;while(Date.now()<end){}",
      }, { cpu_millis = 100 })
      t.eq(cpu_blocked.status, "blocked")
      t.eq(diagnostic(cpu_blocked).reason, "cpu-budget-exceeded")

      local memory_blocked = budget_outcome("memory", {
        "node", "-e", "const b=Buffer.alloc(96*1024*1024,1);setTimeout(()=>process.exit(b[0]===1?0:1),150)",
      }, { memory_mb = 64 })
      t.eq(memory_blocked.status, "blocked")
      t.eq(diagnostic(memory_blocked).reason, "memory-budget-exceeded")

      local disk_blocked = budget_outcome("disk", {
        "node", "-e", "require('fs').writeFileSync('.fixture/disk-budget.bin',Buffer.alloc(70*1024*1024,1))",
      }, { disk_mb = 64 })
      os.remove(checkout_path .. "/.fixture/disk-budget.bin")
      t.eq(disk_blocked.status, "blocked")
      t.eq(diagnostic(disk_blocked).reason, "disk-budget-exceeded")

      local process_blocked = budget_outcome("process", {
        "node", "-e", "const{spawn}=require('child_process');spawn(process.execPath,['-e','setTimeout(()=>{},250)'],{stdio:'ignore'});setTimeout(()=>{},250)",
      }, { processes = 1 })
      t.eq(process_blocked.status, "blocked")
      t.eq(diagnostic(process_blocked).reason, "process-budget-exceeded")

      finalize_ready(ctx, request, ready, ports)
      mark_finalized()
    end)
  end,

  test_foreign_listener_fault_is_isolated_from_happy_path_cleanup = function()
    with_fixture("foreign-listener", function(ctx, request, ports, _, mark_finalized)
      local ready = start_ready(request)
      local foreign_pid
      local ok, failure = pcall(function()
        local state_before = runtime.production().load_state(request.operation_state_ref)
        local app_cleanup_ref = application_cleanup_ref(state_before.state)
        local app_resource = resource_record(ctx, app_cleanup_ref)
        run_argv({
          "node", "-e",
          "try{process.kill(-Number(process.argv[1]),'SIGKILL')}catch(e){try{process.kill(Number(process.argv[1]),'SIGKILL')}catch(_){}}",
          tostring(app_resource.pid),
        }, nil, 5)
        assert_listener_released(ports.application)
        foreign_pid = tonumber(run_argv({
          "node", "-e",
          "const{spawn}=require('child_process');const s=\"require('http').createServer((q,r)=>{r.statusCode=200;r.end('foreign')}).listen(Number(process.argv[1]),'127.0.0.1')\";const c=spawn(process.execPath,['-e',s,process.argv[1]],{detached:true,stdio:'ignore'});c.unref();process.stdout.write(String(c.pid))",
          tostring(ports.application),
        }, nil, 5))
        t.is_true(type(foreign_pid) == "number")
        local foreign_readiness = runtime.production().wait_readiness({
          effect_id = request.dedup_key .. "/environment-factory/readiness/foreign-listener",
          operation_id = request.operation_id,
          artifact_root = request.artifact_root,
          workspace_ref = state_before.state.workspace_ref,
          working_directory = ".",
          checks = { { type = "http", url = request.base_url, expected_status = 200 } },
          runtime_ports = { { name = "application", port = ports.application } },
          process_cleanup_ref = app_cleanup_ref,
          resource_budgets = state_before.state.profile_snapshot.resource_budgets,
          output_bytes = state_before.state.profile_snapshot.resource_budgets.output_bytes,
          timeout_seconds = 2,
        })
        t.eq(foreign_readiness.status, "blocked")
        t.is_true(diagnostic(foreign_readiness).reason:find("foreign-listener", 1, true) ~= nil)
      end)
      if foreign_pid ~= nil then
        pcall(run_argv, {
          "node", "-e",
          "try{process.kill(-Number(process.argv[1]),'SIGKILL')}catch(e){try{process.kill(Number(process.argv[1]),'SIGKILL')}catch(_){}}",
          tostring(foreign_pid),
        }, nil, 5)
      end
      if not ok then error(failure, 0) end

      finalize_ready(ctx, request, ready, ports, { ["application-stopped.json"] = true })
      mark_finalized()
    end)
  end,
}
