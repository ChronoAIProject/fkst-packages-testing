local adapter = require("host_workflow_qa_adapter")
local host_require = require

local M = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function read_source(path)
  local handle = io.open(path, "rb")
  if handle == nil then return nil end
  local source = handle:read("*a")
  handle:close()
  return source
end

local function package_loader(project_root, package_name)
  local root = project_root .. "/packages/" .. package_name
  local cache = {}
  local loading = {}
  local environment = { _G = _G }

  local function load_module(name)
    if cache[name] ~= nil then return cache[name] end
    if loading[name] then error("canonical lifecycle circular package require: " .. package_name .. "/" .. name) end
    local relative = name:gsub("%.", "/")
    local path = root .. "/" .. relative .. ".lua"
    local source = read_source(path)
    if source == nil then
      path = root .. "/" .. relative .. "/init.lua"
      source = read_source(path)
    end
    if source == nil then return host_require(name) end

    loading[name] = true
    local chunk, load_error = load(source, "@" .. path, "t", environment)
    if chunk == nil then
      loading[name] = nil
      error(load_error, 0)
    end
    local ok, value = pcall(chunk, name)
    loading[name] = nil
    if not ok then error(value, 0) end
    cache[name] = value == nil and true or value
    return cache[name]
  end

  environment.require = load_module
  setmetatable(environment, { __index = _G })
  return load_module
end

local function checkpoint_written(prepared, comment_id)
  return {
    schema = "github-proxy.comment-written.v1",
    repo = prepared.comment_request.repo,
    target = "issue",
    issue_number = prepared.comment_request.issue_number,
    comment_id = tostring(comment_id),
    request_dedup_key = prepared.comment_request.dedup_key,
    dedup_key = prepared.comment_request.dedup_key .. "/written/" .. tostring(comment_id),
    handoff = copy(prepared.comment_request.handoff),
    source_ref = copy(prepared.comment_request.source_ref),
  }
end

function M.run(context, project_root, options)
  options = options or {}
  local workflow_modules = package_loader(project_root, "workflow-qa")
  local environment_modules = package_loader(project_root, "environment-factory")
  local readiness_modules = package_loader(project_root, "browser-readiness")
  local design_modules = package_loader(project_root, "testing-design")
  local pipeline_modules = package_loader(project_root, "module-testing-pipeline")
  local loop_modules = package_loader(project_root, "module-test-loop")
  local runner_modules = package_loader(project_root, "testing-runner")
  local artifact_modules = package_loader(project_root, "test-artifacts")
  local publication_modules = package_loader(project_root, "test-publication")

  local workflow = workflow_modules("core")
  local environment = environment_modules("core")
  local readiness = readiness_modules("core")
  local design = design_modules("core")
  local module_pipeline = pipeline_modules("core")
  local module_loop = loop_modules("core")
  local runner = runner_modules("core")
  local planning = runner_modules("structured_planning")
  local structured = runner_modules("structured_execution")
  local artifacts = artifact_modules("core")
  local publication = publication_modules("qa_publication")

  local comment_id = 10000
  local function next_comment_id()
    if type(context.next_comment_id) == "function" then return context:next_comment_id() end
    comment_id = comment_id + 1
    return comment_id
  end
  local function preparation_receipt(request)
    if request.channel ~= "filesystem-dry-run-v1" then
      error("canonical lifecycle preparation requires filesystem-dry-run-v1")
    end
    local materialization_ref = request.artifact_root .. "/published/" .. request.stage .. "-"
      .. tostring(request.attempt) .. "-materialization.json"
    local materialization = {
      schema = "test-publication.qa-materialization-receipt.v1",
      status = "materialized", channel = request.channel, run_id = request.run_id,
      stage = request.stage, attempt = request.attempt, artifact_ref = request.artifact_ref,
      digest = request.artifact_sha256, source_commit = request.repository.commit_sha,
      receipt_ref = materialization_ref, trace_id = request.trace_id, dedup_key = request.dedup_key,
    }
    assert(context.store:write(materialization_ref, materialization))
    local receipt_ref = request.artifact_root .. "/publication-receipts/" .. request.stage .. "-"
      .. tostring(request.attempt) .. ".json"
    local receipt = {
      schema = "test-publication.qa-publication-receipt.v2",
      status = "published", channel = request.channel, github_publication_occurred = false,
      repository = copy(request.repository), run_id = request.run_id, stage = request.stage,
      attempt = request.attempt, artifact_ref = request.artifact_ref,
      artifact_sha256 = request.artifact_sha256, materialization_receipt_ref = materialization_ref,
      materialization_receipt_sha256 = context.store:digest(materialization_ref),
      source_commit = request.repository.commit_sha, receipt_ref = receipt_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
      request_dedup_key = table.concat({ request.dedup_key, "checkpoint", request.stage,
        tostring(request.attempt), request.artifact_sha256 }, "/"),
    }
    assert(context.store:write(receipt_ref, receipt))
    return receipt
  end

  local function release_checkpoint(stage, actions)
    if type(actions) ~= "table" or type(actions[1]) ~= "table"
      or actions[1].queue ~= "test-publication.qa_checkpoint_request" then
      error("canonical lifecycle expected a QA checkpoint request after " .. stage
        .. ", got " .. tostring(type(actions) == "table" and actions[1] and actions[1].queue))
    end
    local receipt
    if options.stop_after_plan == true then
      receipt = preparation_receipt(actions[1].payload)
    else
      local prepared = publication.prepare_checkpoint(actions[1].payload, context.publication_runtime)
      receipt = prepared.receipt
      if receipt == nil then
        if prepared.comment_request == nil then error("canonical lifecycle checkpoint did not request publication") end
        receipt = publication.acknowledge_comment(
          checkpoint_written(prepared, next_comment_id()), context.publication_runtime)
      end
    end
    return workflow.handle_publication_receipt(receipt, context.request, context.workflow_runtime)
  end

  local actions
  if context.workflow_runtime.load_state(context.request.state_ref) == nil then
    actions = release_checkpoint("intake", workflow.start(context.request, context.workflow_runtime))
    local environment_pending = environment.start(actions[1].payload, context.environment_runtime)
    local environment_ready = environment.handle_browser_readiness(
      readiness.result(environment_pending.readiness_check), context.environment_runtime).result
    actions = release_checkpoint("environment-ready", workflow.handle_environment_result(
      environment_ready, context.request, context.workflow_runtime))

    local analysis = design.analyze(actions[1].payload, context.testing_design_runtime)
    actions = release_checkpoint("design-round", workflow.handle_analysis_result(
      analysis, context.request, context.workflow_runtime))
    local post_design_readiness = readiness.result(actions[1].payload)
    actions = release_checkpoint("browser-readiness", workflow.handle_browser_readiness_result(
      post_design_readiness, context.request, context.workflow_runtime))

    local module_request = module_pipeline.module_loop_request(actions[1].payload)
    local runner_action = module_loop.start(module_request, context.module_loop_runtime)
    local runner_request = copy(runner_action[1].payload)
    runner_request.artifact_writer = function(path, body)
      return context.store:write_raw(path, body)
    end
    local module_result = runner.run("module", runner_request)
    local module_terminal_action = module_loop.handle_result(module_result, context.module_loop_runtime)
    actions = release_checkpoint("design-closure", workflow.handle_module_terminal(
      module_terminal_action[1].payload, context.request, context.workflow_runtime))

    local module_plan_artifact = context.store:load(actions[1].payload.module_plan_ref)
    if type(module_plan_artifact) ~= "table" then error("canonical lifecycle module plan is unavailable") end
    if module_plan_artifact.digest ~= actions[1].payload.module_plan_sha256 then
      error("canonical lifecycle module plan digest differs")
    end
    if type(module_plan_artifact.value) ~= "table"
      or module_plan_artifact.value.schema ~= "testing-runner.module-test-plan.v1" then
      error("canonical lifecycle module plan schema differs: "
        .. tostring(type(module_plan_artifact.value) == "table" and module_plan_artifact.value.schema))
    end
    local plan_result = planning.compile(actions[1].payload, context.structured_runtime)
    actions = workflow.handle_plan_result(plan_result, context.request, context.workflow_runtime)
    if plan_result.status ~= "compiled" then
      error("canonical lifecycle structured planning blocked: " .. tostring(plan_result.failure_class))
    end
  else
    actions = workflow.redrive({ limit = 1 }, context.workflow_runtime)
    if #actions == 0 then
      return {
        workflow = workflow, planning = planning, structured = structured,
        publication = publication, no_op = true,
      }
    end
  end

  if options.stop_after_plan == true then
    if type(actions[1]) ~= "table" or actions[1].queue ~= "workflow_qa_execution_grant_request" then
      error("canonical lifecycle preparation expected the persisted execution grant request, got "
        .. tostring(actions[1] and actions[1].queue))
    end
    return {
      workflow = workflow, planning = planning, structured = structured,
      publication = publication, prepared = true, pending_action = copy(actions[1]),
    }
  end

  if type(actions[1]) == "table" and actions[1].queue == "workflow_qa_execution_grant_request" then
    local grant_event = adapter.handle_execution_grant(actions[1].payload, context.generic_host_runtime)
    actions = workflow.handle_grant_result(grant_event.payload, context.request, context.workflow_runtime)
  end

  if type(actions[1]) ~= "table" or actions[1].queue ~= "testing-runner.structured_execution_request" then
    error("canonical lifecycle recovery expected the persisted structured execution request, got "
      .. tostring(actions[1] and actions[1].queue))
  end

  local execution_outcome = structured.run(actions[1].payload, context.structured_runtime)
  if execution_outcome.status == "blocked" then
    local case_artifact = execution_outcome.case_results_path
      and context.store:load(execution_outcome.case_results_path) or nil
    local first
    for _, case in ipairs(case_artifact and case_artifact.value and case_artifact.value.cases or {}) do
      if case.status == "error" then first = case break end
    end
    error("canonical lifecycle structured execution blocked: " .. tostring(execution_outcome.message)
      .. " error_count=" .. tostring(execution_outcome.error_count)
      .. " case=" .. tostring(first and first.case_id)
      .. " status=" .. tostring(first and first.status)
      .. " classification=" .. tostring(first and first.classification))
  end
  if type(context.after_replay_complete) == "function" then
    context:after_replay_complete(execution_outcome, actions[1].payload)
  end
  local execution_result = structured.result_payload(actions[1].payload, context.structured_runtime)
  if execution_result.status == "blocked" then
    error("canonical lifecycle structured execution blocked: " .. tostring(execution_result.stderr_excerpt))
  end
  actions = workflow.handle_execution_result(execution_result, context.request, context.workflow_runtime)
  local summary = artifacts.from_testing_result(actions[1].payload)
  actions = release_checkpoint("execution-batch", workflow.handle_artifact_summary(
    summary, context.request, context.workflow_runtime))

  local cleanup_result = environment.finalize(actions[1].payload, context.environment_runtime)
  actions = release_checkpoint("cleanup", workflow.handle_cleanup_result(
    cleanup_result, context.request, context.workflow_runtime))

  local prepared = publication.prepare_final_report(actions[1].payload, context.publication_runtime)
  local aggregate_receipt = prepared.receipt
  if aggregate_receipt == nil then
    aggregate_receipt = publication.acknowledge_comment(
      checkpoint_written(prepared, next_comment_id()), context.publication_runtime)
  end
  actions = workflow.handle_publication_receipt(
    aggregate_receipt, context.request, context.workflow_runtime)
  adapter.handle_terminal(actions[1].payload, context.generic_host_runtime)

  return {
    workflow = workflow,
    planning = planning,
    structured = structured,
    publication = publication,
    terminal_action = copy(actions[1]),
  }
end

function M.prepare(context, project_root)
  return M.run(context, project_root, { stop_after_plan = true })
end

function M.load_package(project_root, package_name, module_name)
  return package_loader(project_root, package_name)(module_name)
end

return M
