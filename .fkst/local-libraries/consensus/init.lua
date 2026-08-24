local core = require("consensus.core")
local angle_answers = require("consensus.angle_answers")
local rebuttal = require("consensus.rebuttal")
local result_memo = require("consensus.result_memo")
local synthesis = require("consensus.synthesis")
local workflow_codex = require("workflow_internal.codex")
local workflow_sweep = require("workflow_internal.sweep")

local aggregate = core.aggregate
local build_reached_payload = core.build_reached_payload
local judgment_scratch_worktree = core.judgment_scratch_worktree
local parse_angle_output = core.parse_angle_output
local result_memo_key = core.result_memo_key
local result_deferred = workflow_sweep.result_deferred

local M = {}

local function read_runtime_root()
  if type(env_read) == "function" then
    return env_read("FKST_RUNTIME_ROOT")
  end
  local result = exec_sync({ cmd = core.read_runtime_root_cmd(), timeout = 30 })
  if result.exit_code ~= 0 then
    error("consensus: runtime-root-read-failed: FKST_RUNTIME_ROOT read failed: " .. tostring(result.stderr))
  end
  return result.stdout
end

local function prepare_judgment_worktree(path)
  local result = exec_sync({ cmd = core.mkdir_p_cmd(path), timeout = 30 })
  if result.exit_code ~= 0 then
    error("consensus: scratch-directory-setup-failed: judgment scratch directory setup failed: " .. tostring(result.stderr))
  end
  return path
end

local function checkout_root_exists(path)
  local result = exec_sync({ cmd = core.checkout_root_exists_cmd(path), timeout = 30 })
  return result.exit_code == 0
end

local function prepare_seat_worktree(proposal, scratch_path)
  if proposal.worktree == nil then
    return prepare_judgment_worktree(scratch_path)
  end
  if checkout_root_exists(proposal.worktree) then
    return proposal.worktree
  end
  if checkout_root_exists(".") then
    return "."
  end
  error("consensus: judgment-worktree-unavailable: proposal checkout and fallback checkout are unavailable")
end

local function codex_opts(proposal, prompt, worktree, role)
  return core.judgment_codex_opts(prompt, worktree)
end

local function codex_identity(proposal, role, angle_lane, invocation_id)
  local run_role = role or "consensus"
  local invocation_key = tostring(invocation_id or proposal.dedup_key)
  local generation = proposal.generation
  local round = proposal.round
  local lane = tostring(angle_lane)
  return {
    process = {
      role = run_role,
      invocation_id = invocation_key,
    },
    role = run_role,
    invocation_id = invocation_key,
    generation = generation or 0,
    round = round or 0,
    angle_lane = lane,
    dedup_key = "convergence:" .. run_role .. ":" .. invocation_key
      .. ":g" .. tostring(generation or 0)
      .. ":r" .. tostring(round or 0)
      .. ":" .. lane,
  }
end

local function defer_live_run(identity)
  log.info(
    "consensus dept=reach disposition=drop-redrive reason=live-run-active role=" .. tostring(identity.role)
      .. " proposal_id=" .. tostring(identity.invocation_id)
      .. " dedup_key=" .. tostring(identity.dedup_key)
  )
  return {
    deferred = true,
    reason = "live-run-active",
    identity = identity,
  }
end

local function dispatch_codex(proposal, prompt, worktree, role, angle_lane, opts, invocation_id, run_label)
  local run_identity = codex_identity(proposal, role, angle_lane, invocation_id)
  local dispatch_opts = codex_opts(proposal, prompt, worktree, run_identity.role)
  dispatch_opts.label = run_label
  for key, value in pairs(opts or {}) do
    dispatch_opts[key] = value
  end
  local result = workflow_codex.dispatch(run_identity, dispatch_opts)
  if result_deferred(result) then
    return defer_live_run(run_identity)
  end
  return result
end

local function spawn_angle(proposal, angle, runtime_root, invocation_id, run_label)
  local prompt = core.build_angle_prompt(proposal, angle)
  local worktree = prepare_seat_worktree(proposal,
    judgment_scratch_worktree(runtime_root, "angle-" .. tostring(angle), proposal.dedup_key)
  )
  return dispatch_codex(
    proposal,
    prompt,
    worktree,
    "consensus",
    tostring(angle),
    nil,
    invocation_id,
    run_label
  )
end

local function with_runtime_context_root(proposal, runtime_root)
  local value = {}
  for key, field in pairs(proposal) do
    value[key] = field
  end
  value._runtime_context_root = runtime_root
  return value
end

local function next_run_label(new_run_label, phase)
  if new_run_label == nil then
    return nil
  end
  if type(new_run_label) ~= "function" then
    error("consensus: run-label-factory-invalid: new_run_label must be a function")
  end
  local label = new_run_label(phase)
  if label ~= nil and (type(label) ~= "string" or label == "") then
    error("consensus: run-label-invalid: phase label must be a non-empty string")
  end
  return label
end

local function decide(proposal, invocation_id, new_run_label)
  local angle_results = {}
  local handles = {}
  local angles = core.angles(proposal)
  local verdict_mode = core.verdict_mode(proposal)
  for _, angle in ipairs(angles) do
    local run_identity = codex_identity(proposal, "consensus", tostring(angle), invocation_id)
    if workflow_codex.live_run_active(run_identity) then
      return defer_live_run(run_identity)
    end
  end

  local runtime_root = read_runtime_root()
  proposal = with_runtime_context_root(proposal, runtime_root)
  local blind_run_label = next_run_label(new_run_label, "blind")
  for _, angle in ipairs(angles) do
    local handle = spawn_angle(proposal, angle, runtime_root, invocation_id, blind_run_label)
    if result_deferred(handle) then
      return handle
    end
    table.insert(handles, handle)
  end

  local results = await_all(handles)
  for index, angle in ipairs(angles) do
    local parsed = nil
    local result = results[index]
    if type(result) == "table" and result.exit_code == 0 then
      parsed = parse_angle_output(result.stdout, verdict_mode)
    end
    table.insert(angle_results, {
      angle = angle,
      verdict = parsed and parsed.verdict or nil,
      reply = parsed and parsed.reply or nil,
      blocking_gap = parsed and parsed.blocking_gap or nil,
      stdout = type(result) == "table" and result.stdout or nil,
      stderr = type(result) == "table" and result.stderr or nil,
      exit_code = type(result) == "table" and result.exit_code or nil,
    })
  end

  angle_answers.assert_all_valid(angle_results, "blind")

  local decision = aggregate(angle_results, verdict_mode)
  if decision ~= nil then
    return {
      kind = "reached",
      value = build_reached_payload(proposal, decision, angle_results),
    }
  end

  local rebuttal_results = angle_results
  if rebuttal.can_run(angle_results) then
    local rebuttal_run_label = next_run_label(new_run_label, "rebuttal")
    local rebuttal_handles = rebuttal.spawn_all({
      proposal = proposal,
      angle_results = angle_results,
      runtime_root = runtime_root,
      prepare_judgment_worktree = function(path)
        return prepare_seat_worktree(proposal, path)
      end,
      codex_opts = codex_opts,
      build_rebuttal_prompt = function(target_proposal, own_result, peer_results)
        return core.build_rebuttal_prompt(target_proposal, own_result, peer_results)
      end,
      judgment_scratch_worktree = function(root, kind, identity)
        return judgment_scratch_worktree(root, kind, identity)
      end,
      dispatch_codex = function(target_proposal, prompt, worktree, role, angle_lane)
        return dispatch_codex(
          target_proposal,
          prompt,
          worktree,
          role,
          angle_lane,
          nil,
          invocation_id,
          rebuttal_run_label
        )
      end,
    })
    for _, handle in ipairs(rebuttal_handles) do
      if result_deferred(handle) then
        return handle
      end
    end
    local rebuttal_outputs = await_all(rebuttal_handles)
    rebuttal_results = rebuttal.collect(angle_results, rebuttal_outputs, verdict_mode, {
      parse_angle_output = function(stdout, mode)
        return parse_angle_output(stdout, mode)
      end,
    })
    angle_answers.assert_all_valid(rebuttal_results, "rebuttal")
    local rebuttal_reached = rebuttal.post_rebuttal_reached(proposal, angle_results, rebuttal_results, verdict_mode, {
      aggregate = function(items, mode)
        return aggregate(items, mode)
      end,
      assert_all_angle_answers_valid = function(results, phase)
        return angle_answers.assert_all_valid(results, phase)
      end,
      build_reached_payload = function(target_proposal, decision, results, framing, provenance)
        return build_reached_payload(target_proposal, decision, results, framing, provenance)
      end,
    })
    if rebuttal_reached ~= nil then
      return rebuttal_reached
    end
  end

  local parsed = synthesis.parse_or_retry({
    verdict_mode = verdict_mode,
    p1_results = angle_results,
    p2_results = rebuttal_results,
    build_prompt = function(repair, prior_result, parse_failure)
      return core.build_synthesis_prompt(proposal, angle_results, rebuttal_results, {
        repair = repair,
        prior_result = prior_result,
        parse_failure = parse_failure,
      })
    end,
    spawn_sync = function(_kind, prompt)
      local repair = _kind == "synthesis-repair"
      local worktree = prepare_seat_worktree(proposal,
        judgment_scratch_worktree(runtime_root, repair and "synthesis-repair" or "synthesis", proposal.dedup_key)
      )
      return dispatch_codex(proposal, prompt, worktree, "consensus", repair and "synthesis-repair" or "synthesis", {
        sync = true,
      }, invocation_id, next_run_label(new_run_label, _kind))
    end,
  })
  if result_deferred(parsed) then
    return parsed
  end
  return synthesis.to_decision_result(proposal, angle_results, rebuttal_results, parsed, {
    assert_all_angle_answers_valid = function(results, phase)
      return angle_answers.assert_all_valid(results, phase)
    end,
    build_reached_payload = function(target_proposal, decision, results, framing, provenance)
      return build_reached_payload(target_proposal, decision, results, framing, provenance)
    end,
  })
end

local function with_status(status, value)
  local result = {}
  for key, field in pairs(value or {}) do
    result[key] = field
  end
  result.status = status
  return result
end

function M.reach(proposal, options)
  if type(proposal) ~= "table" or proposal.schema ~= "consensus.proposal.v1" then
    log.warn("consensus: unsupported proposal schema")
    return nil
  end
  if not core.is_eligible(proposal) then
    return nil
  end
  local invocation_id = type(options) == "table" and options.invocation_id or proposal.dedup_key
  local new_run_label = type(options) == "table" and options.new_run_label or nil

  local cache_key = result_memo_key(proposal.dedup_key)
  local memoized = result_memo.load(cache_key, proposal.dedup_key)
  if memoized ~= nil then
    return memoized
  end

  local result = decide(proposal, invocation_id, new_run_label)
  if result_deferred(result) then
    return nil
  end

  with_lock(cache_key, function()
    memoized = result_memo.load(cache_key, proposal.dedup_key)
    if memoized == nil and result.kind == "reached" then
      memoized = with_status("reached", result.value)
      result_memo.save(cache_key, memoized)
    end
  end)
  if memoized ~= nil then
    return memoized
  end
  if result.kind == "converge" then
    return with_status("converge", core.build_converge_payload(
      proposal,
      result.narrowed_question,
      result.angle_results,
      result.findings_record,
      { essence_stall = result.essence_stall }
    ))
  end
  error("consensus: decision-result-invalid: unknown decision result")
end

M.core = core

return M
