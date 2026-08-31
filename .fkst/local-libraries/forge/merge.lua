local S = {}
local shared = require("forge.merge.shared")
local ci_gate = require("forge.merge.ci_gate")
local self_heal = require("forge.merge.self_heal")
local verified_merge = require("forge.merge.verified_merge")

function S.install(M, opts)
local merge_opts = opts or {}
if type(merge_opts.github_handle) ~= "function" then
  error("forge.merge: github-handle-required: github_handle is required")
end
if type(merge_opts.read_runtime_root_cmd) ~= "function" then
  error("forge.merge: runtime-root-command-required: read_runtime_root_cmd is required")
end
if type(merge_opts.mkdir_p_cmd) ~= "function" then
  error("forge.merge: mkdir-command-required: mkdir_p_cmd is required")
end
if type(merge_opts.log_info) ~= "function" then
  error("forge.merge: log-info-required: log_info is required")
end
if type(merge_opts.invalidate_pr_after_write) ~= "function" then
  error("forge.merge: invalidate-pr-after-write-required: invalidate_pr_after_write is required")
end
local shared_helpers = shared.install(M, merge_opts)
local ci_gate_exports = ci_gate.install(M, shared_helpers, merge_opts)
self_heal.install(M, shared_helpers, ci_gate_exports, merge_opts)
verified_merge.install(M, shared_helpers, ci_gate_exports, merge_opts)
end

return S
