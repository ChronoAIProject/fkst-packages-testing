-- contract.context_bundle_identity: canonical cache-key and directory identity.
local strings = require("contract.strings")

local C = {}

C.max_cache_key_len = 180
C.max_version_segment_len = 60
C.max_directory_segment_len = 120
C.bundle_cache_prefix = "github-devloop/context-bundle-v2/"
C.manifest_cache_prefix = "github-devloop/context-bundle-manifest-v2/"
C.identity_file_name = "CONTEXT-BUNDLE-IDENTITY"

-- Cache-miss reconstruction intentionally has no old-layout compatibility path.
-- A markerless pre-deploy directory fails stale-generation-context; the next
-- thinking redrive materializes the current identity and emits its canonical key.

local function normalized_segment(value, fallback, keep_slashes)
  local segment = strings.sanitize_key(tostring(value or ""), false)
  if not keep_slashes then
    segment = segment:gsub("[/#]", "-"):gsub("%-+", "-")
  end
  segment = segment:gsub("^%-+", ""):gsub("%-+$", "")
  if segment == "" then
    return fallback
  end
  return segment
end

local function bounded_segment(value, fallback, limit, keep_slashes)
  local segment = normalized_segment(value, fallback, keep_slashes)
  if #segment > limit then
    local suffix = "-" .. strings.decimal_checksum(value)
    segment = segment:sub(1, limit - #suffix):gsub("[/%-]+$", "") .. suffix
  end
  return segment
end

local function directory_segment(key_segment, fallback)
  local segment = normalized_segment(key_segment, fallback, false):gsub("%.+$", "")
  if #segment > C.max_directory_segment_len then
    local suffix = "-" .. strings.decimal_checksum(key_segment)
    segment = segment:sub(1, C.max_directory_segment_len - #suffix):gsub("%-+$", "") .. suffix
  end
  if segment == "" then
    return fallback
  end
  return segment
end

local function from_segments(key, proposal_segment, version_segment)
  return {
    key = key,
    proposal_key_segment = proposal_segment,
    version_key_segment = version_segment,
    proposal_directory_segment = directory_segment(proposal_segment, "proposal"),
    version_directory_segment = directory_segment(version_segment, "version"),
  }
end

function C.from_values(proposal_id, version, prefix)
  local version_segment = bounded_segment(version, "version", C.max_version_segment_len, false)
  local proposal_limit = C.max_cache_key_len - #prefix - 1 - #version_segment
  local proposal_segment = bounded_segment(proposal_id, "proposal", proposal_limit, true)
  local key = prefix .. proposal_segment .. "/" .. version_segment
  return from_segments(key, proposal_segment, version_segment)
end

function C.from_key(key, prefix)
  local value = tostring(key or "")
  if value:sub(1, #prefix) ~= prefix then
    return nil
  end
  local relative = value:sub(#prefix + 1)
  local proposal_segment, version_segment = relative:match("^(.*)/([^/]+)$")
  if proposal_segment == nil or proposal_segment == "" then
    return nil
  end
  return from_segments(value, proposal_segment, version_segment)
end

return C
