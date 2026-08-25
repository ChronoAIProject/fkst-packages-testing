local M = {}

local function env_value(out)
  if type(out) == "string" then
    if out == "" then
      return nil
    end
    return out
  end
  if type(out) ~= "table" or out.exit_code ~= 0 or out.stdout == "" then
    return nil
  end
  return out.stdout
end

local function read_env_value(name, exec, command_builder, opts)
  local command = command_builder(name)
  local run = exec
  local argument = command
  if run == nil and type(env_read) == "function" then
    run = env_read
    argument = name
  elseif run == nil then
    run = exec_sync
  end
  if type(run) ~= "function" then
    if opts and opts.missing_exec_error then
      error(opts.missing_exec_error)
    end
    return nil
  end
  if opts and opts.propagate_exec_errors then
    return env_value(run(argument))
  end
  local ok, out = pcall(run, argument)
  if not ok then
    return nil
  end
  return env_value(out)
end

function M.read_env(name, exec, command_builder)
  if type(name) == "function" then
    local bound_command_builder = name
    local opts = exec
    return function(bound_name, bound_exec)
      return read_env_value(bound_name, bound_exec, bound_command_builder, opts)
    end
  end
  return read_env_value(name, exec, command_builder)
end

return M
