local action_capabilities = require("contract.testing_action_capabilities")
local execution_contract = require("contract.testing_execution")
local ai = require("module_ai_generation")
local cdp_execution = require("module_cdp_execution")
local cdp_runtime = require("module_cdp_runtime")
local native = require("fkst_native")
local receipt_validator = require("testing_runtime.receipt")
local t = fkst.test

local artifact_root = ".testing/runs/registry-click"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function file_exists(path)
  local handle = io.open(path, "r")
  if handle == nil then return false end
  handle:close()
  return true
end

local function real_runtime_ports()
  return {
    exec_argv = function(argv)
      local stdout_path = os.tmpname()
      local stderr_path = os.tmpname()
      local parts = {}
      for _, item in ipairs(argv) do table.insert(parts, shell_quote(item)) end
      local ok, _, exit_code = os.execute(
        table.concat(parts, " ") .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path)
      )
      local result = {
        exit_code = ok == true and 0 or tonumber(exit_code) or 1,
        stdout = file_exists(stdout_path) and read_file(stdout_path) or "",
        stderr = file_exists(stderr_path) and read_file(stderr_path) or "",
      }
      os.remove(stdout_path)
      os.remove(stderr_path)
      return result
    end,
    read = read_file,
    write = function(path, body)
      local directory = path:match("^(.*)/[^/]+$")
      if directory ~= nil then os.execute("mkdir -p " .. shell_quote(directory)) end
      local handle = assert(io.open(path, "w"))
      handle:write(body)
      handle:close()
      return true
    end,
    decode = function(body) return json.decode(body) end,
  }
end

local function remove_acceptance_artifacts()
  assert(artifact_root == ".testing/runs/registry-click")
  os.execute("rm -rf " .. shell_quote(artifact_root))
end

local function stop_harness(pid, state_path, log_path)
  if pid ~= nil then os.execute("kill " .. tostring(pid) .. " >/dev/null 2>&1") end
  os.remove(state_path)
  os.remove(log_path)
end

local function start_harness()
  local state_path = os.tmpname()
  local log_path = state_path .. ".log"
  local harness_path = file_exists("packages/testing-runner/tests/fixtures/registry_click_harness.js")
    and "packages/testing-runner/tests/fixtures/registry_click_harness.js"
    or "tests/fixtures/registry_click_harness.js"
  os.remove(state_path)
  local command = table.concat({
    "node",
    shell_quote(harness_path),
    "--state",
    shell_quote(state_path),
    ">",
    shell_quote(log_path),
    "2>&1 & echo $!",
  }, " ")
  local process = assert(io.popen(command))
  local pid = tonumber(process:read("*l"))
  process:close()
  if pid == nil then error("registry-click-test: failed to start browser harness") end

  for _ = 1, 300 do
    local handle = io.open(state_path, "r")
    if handle ~= nil then
      local body = handle:read("*a")
      handle:close()
      local state = json.decode(body)
      if state.error ~= nil then
        local log = file_exists(log_path) and read_file(log_path) or ""
        stop_harness(pid, state_path, log_path)
        error("registry-click-test: " .. tostring(state.error) .. " " .. log)
      end
      return state, pid, state_path, log_path
    end
    os.execute("sleep 0.05")
  end

  local log = file_exists(log_path) and read_file(log_path) or ""
  stop_harness(pid, state_path, log_path)
  error("registry-click-test: browser harness did not become ready " .. log)
end

local function origin(url)
  return assert(url:match("^(http://[^/]+)"))
end

local function ai_request()
  return {
    schema = ai.request_schema,
    mode = "autonomous-reviewed",
    case_budget = 1,
    allowed_case_kinds = { "read-only-interaction" },
    allowed_action_kinds = { "click" },
    context_manifest_path = artifact_root .. "/ai-context-manifest.json",
    generated_cases_path = artifact_root .. "/generated-test-cases.json",
    generated_case_gate_path = artifact_root .. "/generated-case-gate.json",
    ai_agent_generation_path = artifact_root .. "/ai-agent-generation.json",
    generated_case_agent_review_path = artifact_root .. "/generated-case-agent-review.json",
    ai_test_design_loop_path = artifact_root .. "/ai-test-design-loop.json",
  }
end

local function context_for(base_url, request)
  return ai.build_context({
    readiness = { status = "ready" },
    limitations = {},
    modules = {
      {
        id = "registry-click",
        name = "Registry click",
        entry_url = base_url,
        evidence_pointer = artifact_root .. "/source-observation.json",
      },
    },
  }, {
    base_url = base_url,
    allowed_origins = { origin(base_url) },
    mutation_policy = "read-only",
  }, artifact_root, {
    ai_generation = request,
    step_budget = 1,
    case_priorities = { "P2" },
  })
end

local function candidates(action_kind)
  return {
    schema = ai.candidate_schema,
    cases = {
      {
        module_id = "registry-click",
        priority = "P2",
        title = "Execute the registered click",
        objective = "Click the fixture button and verify its deterministic result marker.",
        case_kind = "read-only-interaction",
        actions = {
          {
            action = action_kind,
            target = { type = "css-selector", selector = "#registry-click-button" },
            expected = {
              type = "visible-dom-target",
              target = { type = "css-selector", selector = "#registry-click-result" },
            },
          },
        },
        expected_observable = "The registered click result becomes visible.",
      },
    },
  }
end

local function approval_result(proposal_id, source_ref, extra)
  local value = {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal_id,
    decision = "approve",
    source_ref = source_ref,
    angle_results = {
      { angle = "teleology", verdict = "approve", exit_code = 0 },
      { angle = "parsimony", verdict = "approve", exit_code = 0 },
      { angle = "fidelity", verdict = "approve", exit_code = 0 },
      { angle = "natural-ownership", verdict = "approve", exit_code = 0 },
      { angle = "proportional-containment", verdict = "approve", exit_code = 0 },
    },
  }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function reviewed_documents(base_url)
  local request = ai_request()
  local context = context_for(base_url, request)
  local generated = ai.canonicalize_candidates(context, request, candidates("click"), "registry-click-model")
  local gate = ai.gate_generated_cases(generated, context, request)
  local agent_generation = ai.generation_from_agent_results(context, approval_result("registry-click-generation", {
    kind = "testing-ai-generation",
    ref = artifact_root,
  }, {
    candidate_generation_digest = generated.generation_digest,
    generated_case_count = generated.case_count,
  }))
  local agent_review = ai.review_from_agent_results(context, gate, approval_result("registry-click-review", {
    kind = "testing-ai-review",
    ref = artifact_root,
  }))
  local closure = ai.build_review_closure(context, generated, gate, agent_generation, agent_review)
  local documents = {
    [context.context_manifest_path] = context,
    [context.generated_cases_path] = generated,
    [context.generated_case_gate_path] = gate,
    [context.ai_agent_generation_path] = agent_generation,
    [context.generated_case_agent_review_path] = agent_review,
    [context.ai_test_design_loop_path] = closure,
  }
  local encoded = {}
  for path, document in pairs(documents) do encoded[path] = native.json_encode(document) .. "\n" end
  return request, gate, encoded
end

local function runtime_payload(state, request)
  return {
    module = "registry-click",
    ui_loop = {
      base_url = state.base_url,
      allowed_origins = { origin(state.base_url) },
      cdp_readiness_ref = "registry-click-cdp-ready",
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "registry-click",
          name = "Registry click",
          entry_url = state.base_url,
          visible_label = "Registry click",
          discovery_source = "browser-visible",
          confidence = "high",
          evidence_pointer = artifact_root .. "/source-observation.json",
        },
      },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 1,
      case_priorities = { "P2" },
      ai_generation = request,
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "test", status = "ready", cdp_url = state.cdp_url },
      },
    },
  }
end

local function registered_execution_request()
  local definition = action_capabilities.require("click")
  return {
    schema = execution_contract.schemas.execution_request,
    module = "registry-click",
    trace_id = "trace-registry-click",
    dedup_key = "registry-click",
    artifact_root = artifact_root,
    base_url = "http://127.0.0.1:43111/registry-click",
    allowed_origins = { "http://127.0.0.1:43111" },
    cdp_url = "http://127.0.0.1:43112",
    step_budget = 1,
    plan_sha256 = string.rep("a", 64),
    actions = {
      {
        step = 1,
        module_id = "registry-click",
        case_id = "registry-click:click",
        priority = "P0",
        action = "click",
        target = { type = "css-selector", selector = "#registry-click-button" },
        expected = {
          type = "visible-dom-target",
          target = { type = "css-selector", selector = "#registry-click-result" },
        },
        url = "http://127.0.0.1:43111/registry-click",
        runtime_handler = definition.runtime_handler,
        preconditions = definition.preconditions,
        evidence_requirements = definition.evidence_requirements,
        assertions = {
          {
            type = definition.observation_requirements.type,
            target = { type = "css-selector", selector = "#registry-click-result" },
          },
        },
      },
    },
  }
end

local function registered_execution_receipt()
  local evidence_pointer = artifact_root .. "/evidence/execution/registry-click-click.json"
  return {
    schema = execution_contract.schemas.execution_receipt,
    module = "registry-click",
    request_sha256 = string.rep("a", 64),
    status = "passed",
    classification = "typed-browser-assertions-passed",
    action_count = 1,
    executed_action_count = 1,
    failed_action_count = 0,
    blocked_action_count = 0,
    actions = {
      {
        step = 1,
        case_id = "registry-click:click",
        action = "click",
        execution_status = "executed",
        assertion_status = "passed",
        observation = "typed browser action and assertions completed",
        evidence_pointer = evidence_pointer,
        assertion_results = {
          {
            type = "visible-dom-target",
            status = "passed",
            observation = "visible DOM target: #registry-click-result",
            evidence_pointer = evidence_pointer,
          },
        },
        resolved_target = {
          type = "css-selector",
          selector = "#registry-click-button",
          node_name = "button",
          node_id = "registry-click-button",
        },
        observed_post_action_state = {
          type = "visible-dom-target",
          target = { type = "css-selector", selector = "#registry-click-result" },
          visible = true,
          text = "Registered click completed",
          was_visible_before = false,
        },
      },
    },
  }
end

return {
  test_click_registry_definition_is_complete_and_typed = function()
    local definition = action_capabilities.require("click")
    t.eq(definition.action_kind, "click")
    t.eq(definition.target_requirements.type, "dom-target")
    t.eq(definition.target_requirements.locator, "css-selector")
    t.eq(definition.target_requirements.required, true)
    t.eq(definition.preconditions[4], "expected-observation-absent")
    t.eq(definition.observation_requirements.type, "visible-dom-target")
    t.eq(definition.evidence_requirements[2], "resolved_target")
    t.eq(definition.evidence_requirements[3], "observed_post_action_state")
    t.eq(definition.runtime_handler, "cdp.click")
  end,

  test_click_registry_rejects_malformed_typed_contracts = function()
    t.raises(function()
      action_capabilities.validate_target(
        { type = "css-selector", selector = "#button" },
        "target",
        { type = "unsupported", locator = "css-selector", required = true }
      )
    end)
    t.raises(function()
      action_capabilities.validate_target({ type = "text", selector = "Run" })
    end)
    t.raises(function()
      action_capabilities.validate_expected({
        type = "text-present",
        target = { type = "css-selector", selector = "#result" },
      })
    end)
    t.raises(function()
      action_capabilities.validate_expected({ type = "visible-dom-target" })
    end)
    t.raises(function()
      action_capabilities.validate_resolved_target({
        type = "css-selector",
        selector = "#button",
        node_name = "button",
        node_id = "",
      })
    end)
    t.raises(function()
      action_capabilities.validate_observed_post_action_state({
        type = "text-present",
        target = { type = "css-selector", selector = "#result" },
        visible = true,
        text = "done",
        was_visible_before = false,
      })
    end)
    t.raises(function()
      action_capabilities.validate_observed_post_action_state({
        type = "visible-dom-target",
        target = { type = "css-selector", selector = "#result" },
        visible = true,
        text = "done",
        was_visible_before = true,
      })
    end)
  end,

  test_execution_contract_fails_closed_for_registry_and_legacy_mismatches = function()
    local request = registered_execution_request()
    t.eq(execution_contract.validate_execution_request(request).actions[1].action, "click")

    request = registered_execution_request()
    request.actions[1].assertions[1].type = "unknown-assertion"
    t.raises(function() execution_contract.validate_execution_request(request) end)

    request = registered_execution_request()
    request.actions[1].runtime_handler = "cdp.other"
    t.raises(function() execution_contract.validate_execution_request(request) end)

    request = registered_execution_request()
    request.actions[1].preconditions = { "target-present" }
    t.raises(function() execution_contract.validate_execution_request(request) end)

    request = registered_execution_request()
    request.actions[1].evidence_requirements = { "action" }
    t.raises(function() execution_contract.validate_execution_request(request) end)

    request = registered_execution_request()
    local action = request.actions[1]
    action.action = "navigate"
    action.target = action.url
    action.expected = nil
    action.preconditions = nil
    action.evidence_requirements = nil
    action.assertions = { { type = "url-within-scope" } }
    t.raises(function() execution_contract.validate_execution_request(request) end)

    local receipt = registered_execution_receipt()
    t.eq(execution_contract.validate_execution_receipt(receipt).status, "passed")
    receipt.actions[1].action = "navigate"
    receipt.actions[1].assertion_results[1].type = "url-within-scope"
    t.raises(function() execution_contract.validate_execution_receipt(receipt) end)
  end,

  test_registered_receipt_is_bound_to_requested_and_observed_targets = function()
    local request = registered_execution_request()
    local receipt = registered_execution_receipt()
    t.eq(receipt_validator.validate(request, receipt).status, "passed")

    receipt = registered_execution_receipt()
    receipt.actions[1].resolved_target.selector = "#other-button"
    t.raises(function() receipt_validator.validate(request, receipt) end)

    receipt = registered_execution_receipt()
    receipt.actions[1].observed_post_action_state.target.selector = "#other-result"
    t.raises(function() receipt_validator.validate(request, receipt) end)
  end,

  test_ai_validation_derives_click_support_and_rejects_unregistered_action = function()
    local request = ai_request()
    local context = context_for("http://127.0.0.1:43111/registry-click", request)
    local generated = ai.canonicalize_candidates(context, request, candidates("click"), "registry-click-model")
    local gate = ai.gate_generated_cases(generated, context, request)
    t.eq(gate.status, "reviewed")
    t.eq(gate.executable_count, 1)
    t.eq(gate.cases[1].actions[1].target.selector, "#registry-click-button")

    generated.cases[1].actions[1].action = "unregistered-click-like-action"
    local rejected = ai.gate_generated_cases(generated, context, request)
    t.eq(rejected.status, "blocked")
    t.eq(rejected.rejected_count, 1)
    t.eq(rejected.decisions[1].classification, "unregistered-action")
    t.is_true(rejected.decisions[1].reason:find("unregistered-action", 1, true) ~= nil)
  end,

  test_runtime_planning_rejects_unregistered_action_before_execution = function()
    local executions = 0
    local writes = 0
    local ok, err = pcall(cdp_runtime.run, {
      base_url = "http://127.0.0.1:43111/registry-click",
      allowed_origins = { "http://127.0.0.1:43111" },
      actions = {
        {
          module_id = "registry-click",
          case_id = "registry-click:unregistered",
          priority = "P0",
          action = "unregistered-click-like-action",
          target = "Registry click",
          url = "http://127.0.0.1:43111/registry-click",
          execution_status = "planned",
        },
      },
    }, {
      trace_id = "trace-registry-click",
      dedup_key = "registry-click",
      artifact_root = artifact_root,
    }, {
      module = "registry-click",
      preflight_result = {
        status = "ready",
        sessions = { { role = "test", status = "ready", cdp_url = "http://127.0.0.1:43112" } },
      },
    }, {
      exec_argv = function() executions = executions + 1 end,
      read = function() return "" end,
      write = function() writes = writes + 1 return true end,
      decode = function() return {} end,
    })
    t.eq(ok, false)
    t.eq(executions, 0)
    t.eq(writes, 0)
    t.is_true(tostring(err):find("unregistered-action", 1, true) ~= nil)
  end,

  test_registry_approved_click_executes_through_real_cdp_and_returns_evidence = function()
    local state, pid, state_path, log_path = start_harness()
    local ok, failure = pcall(function()
      remove_acceptance_artifacts()
      os.execute("mkdir -p " .. shell_quote(artifact_root))
      local request, gate, documents = reviewed_documents(state.base_url)
      t.eq(gate.executable_count, 1)
      local payload = runtime_payload(state, request)
      local artifact = cdp_execution.build(payload, artifact_root, {
        readiness = { status = "ready" },
        artifact_reader = function(path) return documents[path] end,
      })
      t.eq(artifact.execution_status, "planned")
      t.eq(artifact.action_count, 1)
      t.eq(artifact.actions[1].action, "click")
      t.eq(artifact.actions[1].target.selector, "#registry-click-button")

      local terminal = cdp_runtime.run(artifact, {
        trace_id = "trace-registry-click",
        dedup_key = "registry-click",
        artifact_root = artifact_root,
      }, payload, real_runtime_ports())
      t.eq(terminal.execution_status, "passed")
      t.eq(terminal.executed_action_count, 1)
      t.eq(terminal.actions[1].resolved_target.selector, "#registry-click-button")
      t.eq(terminal.actions[1].observed_post_action_state.target.selector, "#registry-click-result")
      t.eq(terminal.actions[1].observed_post_action_state.was_visible_before, false)
      t.eq(terminal.actions[1].observed_post_action_state.visible, true)

      local evidence = json.decode(read_file(terminal.actions[1].evidence_pointer))
      t.eq(evidence.action, "click")
      t.eq(evidence.resolved_target.node_name, "button")
      t.eq(evidence.observed_post_action_state.text, "Registered click completed")
      t.eq(evidence.observed_post_action_state.visible, true)
    end)
    stop_harness(pid, state_path, log_path)
    remove_acceptance_artifacts()
    if not ok then error(failure, 0) end
  end,
}
