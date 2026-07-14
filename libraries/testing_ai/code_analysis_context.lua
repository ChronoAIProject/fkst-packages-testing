local artifact_contract = require("code_analysis.artifact")

local C = {}

function C.verify(reference, ports)
  if reference == nil then return nil end
  local artifact, _, verified_reference = artifact_contract.load_verified(reference, ports)
  local facts = {}
  for _, fact in ipairs(artifact.facts) do
    table.insert(facts, {
      id = fact.id,
      kind = fact.kind,
      name = fact.name,
      pointer = fact.pointer,
      source = {
        path = fact.source.path,
        line = fact.source.line,
        column = fact.source.column,
      },
    })
  end
  return {
    artifact_pointer = verified_reference.artifact_pointer,
    artifact_digest = verified_reference.artifact_digest,
    artifact_version = verified_reference.artifact_version,
    facts = facts,
    fact_count = #facts,
  }
end

function C.validate_binding(reference, verified)
  if reference == nil then
    if verified ~= nil then error("testing-runner: code-analysis-binding-mismatch: unexpected verified artifact") end
    return nil
  end
  artifact_contract.validate_reference(reference)
  if type(verified) ~= "table"
    or verified.artifact_pointer ~= reference.artifact_pointer
    or verified.artifact_digest ~= reference.artifact_digest
    or verified.artifact_version ~= reference.artifact_version then
    error("testing-runner: code-analysis-binding-mismatch: verified artifact does not match inventory reference")
  end
  return verified
end

function C.fact_index(context)
  local facts = {}
  for _, fact in ipairs((((context or {}).code_analysis or {}).facts) or {}) do facts[fact.pointer] = fact end
  return facts
end

function C.verified_fact(context, pointer)
  if pointer == nil then return nil end
  local fact = C.fact_index(context)[pointer]
  if fact == nil then error("testing-runner: malformed-ai-candidate: code_fact_pointer is not verified") end
  return fact
end

function C.add_provenance(provenance, context, fact)
  if fact == nil then return provenance end
  provenance.code_analysis_artifact_pointer = context.code_analysis.artifact_pointer
  provenance.code_analysis_digest = context.code_analysis.artifact_digest
  provenance.code_analysis_version = context.code_analysis.artifact_version
  provenance.code_fact_pointers = { fact.pointer }
  return provenance
end

function C.validate_provenance(value, context, dense_list, max_pointers, copy)
  local has_binding = value.code_analysis_artifact_pointer ~= nil
    or value.code_analysis_digest ~= nil
    or value.code_analysis_version ~= nil
    or value.code_fact_pointers ~= nil
  if not has_binding then return copy end
  local binding = context.code_analysis
  if type(binding) ~= "table"
    or value.code_analysis_artifact_pointer ~= binding.artifact_pointer
    or value.code_analysis_digest ~= binding.artifact_digest
    or value.code_analysis_version ~= binding.artifact_version then
    error("testing-runner: malformed-generated-case: code-analysis provenance does not match verified context")
  end
  local ok_pointers, pointer_count = dense_list(value.code_fact_pointers)
  if not ok_pointers or pointer_count == 0 or pointer_count > max_pointers then
    error("testing-runner: malformed-generated-case: code_fact_pointers must be a non-empty bounded list")
  end
  local facts = C.fact_index(context)
  copy.code_fact_pointers = {}
  for _, pointer in ipairs(value.code_fact_pointers) do
    if facts[pointer] == nil then error("testing-runner: malformed-generated-case: code fact pointer is not verified") end
    table.insert(copy.code_fact_pointers, pointer)
  end
  copy.code_analysis_artifact_pointer = binding.artifact_pointer
  copy.code_analysis_digest = binding.artifact_digest
  copy.code_analysis_version = binding.artifact_version
  return copy
end

function C.provenance_has_fact(provenance, pointer)
  if pointer == nil then return true end
  for _, item in ipairs((provenance or {}).code_fact_pointers or {}) do
    if item == pointer then return true end
  end
  return false
end

return C
