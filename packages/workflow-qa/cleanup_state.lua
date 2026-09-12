local C = {}

local function verify_retention_snapshots(state, receipt, ports, deps)
  local snapshots = {}
  local ledger_ids = {}
  for _, resource in ipairs(receipt.remaining_resources) do
    if resource.resource_kind == "worker-home-ledger" then
      local detail_ref = resource.resource_detail_ref.ref
      local actual_sha256 = deps.digest(ports, detail_ref)
      if actual_sha256 ~= resource.resource_detail_sha256 then
        error("workflow-qa: cleanup-unverified: worker-home retention digest differs")
      end
      local snapshot = deps.load_bound(ports, detail_ref, actual_sha256,
        "worker-home-retention")
      deps.environment_contract.validate_worker_home_retention(snapshot)
      if snapshot.operation_id ~= state.request.run_id
        or not deps.environment_contract.same_repository(snapshot.repository,
          state.request.repository)
        or snapshot.remaining_count ~= resource.remaining_count then
        error("workflow-qa: cleanup-unverified: worker-home retention binding differs")
      end
      if ledger_ids[snapshot.ledger_id] then
        error("workflow-qa: cleanup-unverified: duplicate worker-home retention ledger")
      end
      ledger_ids[snapshot.ledger_id] = true
      state.digests[detail_ref] = actual_sha256
      table.insert(snapshots, {
        resource_id = resource.resource_id,
        ledger_id = snapshot.ledger_id,
        resource_detail_ref = deps.copy(resource.resource_detail_ref),
        resource_detail_sha256 = actual_sha256,
        remaining_count = snapshot.remaining_count,
      })
    end
  end
  return snapshots
end

function C.accept(state, payload, ports, deps)
  if payload.cleanup_receipt_ref == nil then
    error("workflow-qa: cleanup-unverified: cleanup receipt is missing")
  end
  local ref = payload.cleanup_receipt_ref.ref
  local sha256 = deps.digest(ports, ref)
  local receipt = deps.load_bound(ports, ref, sha256, "cleanup-receipt")
  deps.environment_contract.validate_cleanup_receipt(receipt)
  if receipt.status ~= payload.cleanup_status
    or receipt.operation_id ~= state.request.run_id
    or receipt.artifact_root ~= state.request.environment_start.artifact_root
    or receipt.trace_id ~= state.request.trace_id
    or receipt.dedup_key ~= state.request.dedup_key then
    error("workflow-qa: cleanup-unverified: cleanup receipt binding differs")
  end

  state.cleanup_result = deps.copy(payload)
  state.digests[ref] = sha256
  if payload.cleanup_status == "incomplete" then
    local retention_snapshots = verify_retention_snapshots(state, receipt, ports, deps)
    state.terminal_status = "blocked"
    state.cleanup_blocked = {
      status = "blocked",
      reason = "cleanup-incomplete",
      cleanup_receipt_ref = ref,
      cleanup_receipt_sha256 = sha256,
      remaining_resources = deps.copy(receipt.remaining_resources),
      worker_home_retention = retention_snapshots,
    }
    state.phase = "cleanup-blocked"
    state.pending_actions = {}
    deps.save(ports, state)
    return {}
  end
  if payload.cleanup_status ~= "complete" then
    error("workflow-qa: cleanup-unverified: cleanup status is not terminal")
  end
  return deps.prepare_finalization(state, ports)
end

return C
