local exec_wrap = require("forge.git.exec")
local argv_render = require("forge.argv")

local M = {}
local production_handles = {}

function M.path_is_directory_cmd(path)
  local value = tostring(path or "")
  if value == "" or value:find("[\r\n]") ~= nil then
    error("github-devloop: directory-path-invalid: invalid directory path")
  end
  return "[ -d " .. argv_render.shell_single_quote(value) .. " ]"
end

function M.run_path_is_directory(path, timeout)
  return exec_sync({ cmd = M.path_is_directory_cmd(path), timeout = timeout or 30 })
end

function M.git_worktree_remove_if_present(worktree, timeout, worktree_remove)
  local dir_result = M.run_path_is_directory(worktree, 30)
  if dir_result.exit_code == 1 then
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  if dir_result.exit_code ~= 0 then
    return dir_result
  end
  return worktree_remove(worktree, timeout)
end

function M.new(exec)
  assert(type(exec) == "function", "forge.git.new requires an exec function")
  local handle = {}
  function handle._exec(argv, timeout, context)
    return exec_wrap.run(exec, argv, timeout, context)
  end
  require("forge.git.refs").install(handle)
  function handle.git_worktree_remove_if_present(worktree, timeout)
    return M.git_worktree_remove_if_present(worktree, timeout, handle.worktree_remove)
  end
  return handle
end

function M.production_handle(owner)
  local key = tostring(owner or "forge.git")
  local handle = production_handles[key]
  if handle == nil then
    if type(exec_argv) ~= "function" then
      error(key .. ": git adapter requires exec_argv")
    end
    handle = M.new(exec_argv)
    production_handles[key] = handle
  end
  return handle
end

return M
