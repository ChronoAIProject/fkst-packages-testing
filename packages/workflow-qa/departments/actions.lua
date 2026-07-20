local M = {}

function M.raise_all(actions)
  for _, item in ipairs(actions or {}) do raise(item.queue, item.payload) end
end

return M
