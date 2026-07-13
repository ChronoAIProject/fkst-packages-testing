-- contract.source_ref: structural helpers for stable {kind, ref} source pointers.
local strings = require("contract.strings")

local R = {}

function R.has_bounded_source_ref(source_ref, limit)
  return type(source_ref) == "table"
    and strings.is_bounded_string(source_ref.kind, limit)
    and strings.is_bounded_string(source_ref.ref, limit)
end

function R.version_order_key(version)
  return require("contract.transition_version").version_order_key(version)
end

return R
