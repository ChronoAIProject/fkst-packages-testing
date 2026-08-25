-- contract.github_issue_create: field limits for github-proxy.issue-create.v1.
local C = {}

local field_limits = {
  repo = 200,
  title = 240,
  body = 12000,
  dedup_key = 512,
  source_ref_kind = 80,
  source_ref_ref = 200,
}

function C.limits()
  local copy = {}
  for field, limit in pairs(field_limits) do
    copy[field] = limit
  end
  return copy
end

return C
