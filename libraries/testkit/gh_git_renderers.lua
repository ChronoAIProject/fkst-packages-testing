local M = {}

local function shell_single_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function parent_dir(worktree)
  return tostring(worktree):gsub("/+$", ""):match("^(.*)/[^/]+$") or "."
end

function M.install(core)
  core.git_status_cmd = core.git_status_cmd or function(worktree)
    return "git -C " .. shell_single_quote(worktree) .. " status --porcelain"
  end
  core.git_add_all_cmd = core.git_add_all_cmd or function(worktree)
    return "git -C " .. shell_single_quote(worktree) .. " add -A"
  end
  core.git_commit_cmd = core.git_commit_cmd or function(worktree, message)
    return "git -C " .. shell_single_quote(worktree) .. " commit -m " .. shell_single_quote(message)
  end
  core.git_empty_commit_cmd = core.git_empty_commit_cmd or function(worktree, message)
    return "git -C " .. shell_single_quote(worktree) .. " commit --allow-empty -m " .. shell_single_quote(message)
  end
  core.git_current_branch_cmd = core.git_current_branch_cmd or function(worktree)
    if worktree == nil then
      return "git rev-parse --abbrev-ref HEAD"
    end
    return "git -C " .. shell_single_quote(worktree) .. " rev-parse --abbrev-ref HEAD"
  end
  core.git_head_sha_cmd = core.git_head_sha_cmd or function(worktree)
    return "git -C " .. shell_single_quote(worktree) .. " rev-parse HEAD"
  end
  core.git_base_head_cmd = core.git_base_head_cmd or function(branch)
    return "git rev-parse --verify refs/remotes/origin/" .. shell_single_quote(branch) .. "^{commit}"
  end
  core.git_fetch_branch_cmd = core.git_fetch_branch_cmd or function(remote, branch)
    return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote(branch)
  end
  core.git_fetch_pr_merge_ref_cmd = core.git_fetch_pr_merge_ref_cmd or function(remote, number)
    return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote("refs/pull/" .. tostring(number) .. "/merge")
  end
  core.git_fetch_pr_head_ref_cmd = core.git_fetch_pr_head_ref_cmd or function(remote, number)
    return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote("refs/pull/" .. tostring(number) .. "/head")
  end
  core.git_fetch_head_commit_cmd = core.git_fetch_head_commit_cmd or function()
    return "git rev-parse --verify FETCH_HEAD^{commit}"
  end
  core.git_remote_branch_head_cmd = core.git_remote_branch_head_cmd or function(remote, branch)
    return "git rev-parse --verify refs/remotes/" .. shell_single_quote(remote) .. "/" .. shell_single_quote(branch) .. "^{commit}"
  end
  core.git_ls_remote_branch_cmd = core.git_ls_remote_branch_cmd or function(remote, branch)
    return "git ls-remote " .. shell_single_quote(remote) .. " refs/heads/" .. shell_single_quote(branch)
  end
  core.git_fetch_remote_branch_to_tracking_ref_cmd = core.git_fetch_remote_branch_to_tracking_ref_cmd or function(remote, branch, tracking_ref)
    return "git fetch " .. shell_single_quote(remote) .. " " .. shell_single_quote("refs/heads/" .. tostring(branch) .. ":" .. tostring(tracking_ref))
  end
  core.git_rev_parse_ref_commit_cmd = core.git_rev_parse_ref_commit_cmd or function(ref)
    return "git rev-parse --verify " .. shell_single_quote(tostring(ref) .. "^{commit}")
  end
  core.git_worktree_merge_no_edit_cmd = core.git_worktree_merge_no_edit_cmd or function(worktree, sha)
    return "git -C " .. shell_single_quote(worktree) .. " merge --no-edit " .. shell_single_quote(sha)
  end
  core.git_worktree_add_new_branch_cmd = core.git_worktree_add_new_branch_cmd or function(worktree, branch, base)
    return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
      .. " && git worktree add -b " .. shell_single_quote(branch)
      .. " " .. shell_single_quote(worktree)
      .. " " .. shell_single_quote(base)
  end
  core.git_worktree_add_reset_branch_cmd = core.git_worktree_add_reset_branch_cmd or function(worktree, branch, base)
    return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
      .. " && git worktree add -B " .. shell_single_quote(branch)
      .. " " .. shell_single_quote(worktree)
      .. " " .. shell_single_quote(base)
  end
  core.git_worktree_add_existing_branch_cmd = core.git_worktree_add_existing_branch_cmd or function(worktree, branch)
    return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
      .. " && git worktree add " .. shell_single_quote(worktree)
      .. " " .. shell_single_quote(branch)
  end
  core.git_worktree_add_remote_branch_cmd = core.git_worktree_add_remote_branch_cmd or function(worktree, remote, branch, force)
    return "mkdir -p " .. shell_single_quote(parent_dir(worktree))
      .. " && git worktree add" .. (force and " --force" or "")
      .. " -B " .. shell_single_quote(branch)
      .. " " .. shell_single_quote(worktree)
      .. " refs/remotes/" .. shell_single_quote(remote) .. "/" .. shell_single_quote(branch)
  end
  core.git_worktree_reset_hard_cmd = core.git_worktree_reset_hard_cmd or function(worktree, branch)
    return "git -C " .. shell_single_quote(worktree) .. " reset --hard refs/heads/" .. shell_single_quote(branch)
  end
  core.git_worktree_clean_cmd = core.git_worktree_clean_cmd or function(worktree)
    return "git -C " .. shell_single_quote(worktree) .. " clean -fd"
  end
  core.git_ahead_count_cmd = core.git_ahead_count_cmd or function(upstream, integration)
    return "git rev-list --count refs/remotes/origin/" .. shell_single_quote(upstream) .. "..refs/remotes/origin/" .. shell_single_quote(integration)
  end
  core.git_show_ref_branch_cmd = core.git_show_ref_branch_cmd or function(branch)
    return "git show-ref --verify --quiet refs/heads/" .. shell_single_quote(branch)
  end
  core.git_show_ref_cmd = core.git_show_ref_cmd or function(worktree, branch)
    return "git -C " .. shell_single_quote(worktree) .. " show-ref --verify --quiet refs/heads/" .. shell_single_quote(branch)
  end
  core.git_branch_ahead_count_cmd = core.git_branch_ahead_count_cmd or function(base, branch)
    return "git rev-list --count " .. shell_single_quote(tostring(base) .. "..refs/heads/" .. tostring(branch))
  end
  core.git_branch_head_cmd = core.git_branch_head_cmd or function(branch)
    return "git rev-parse --verify refs/heads/" .. shell_single_quote(branch)
  end
  core.git_push_branch_cmd = core.git_push_branch_cmd or function(branch)
    return "git push origin " .. shell_single_quote(branch)
  end
  core.git_switch_branch_cmd = core.git_switch_branch_cmd or function(worktree, branch)
    return "git -C " .. shell_single_quote(worktree) .. " switch " .. shell_single_quote(branch)
  end
  core.git_rev_parse_branch_cmd = core.git_rev_parse_branch_cmd or function(worktree, branch)
    return "git -C " .. shell_single_quote(worktree) .. " rev-parse --verify refs/heads/" .. shell_single_quote(branch)
  end
  core.git_worktree_list_cmd = core.git_worktree_list_cmd or function()
    return "git worktree list --porcelain"
  end
  core.git_worktree_remove_cmd = core.git_worktree_remove_cmd or function(worktree)
    return "git worktree remove --force " .. shell_single_quote(worktree)
  end
  core.git_worktree_prune_cmd = core.git_worktree_prune_cmd or function()
    return "git worktree prune"
  end
  core.git_worktree_force_clean_cmd = core.git_worktree_force_clean_cmd or function(worktree)
    local quoted = shell_single_quote(worktree)
    return "git worktree remove --force " .. quoted .. " 2>/dev/null; rm -rf " .. quoted .. "; git worktree prune"
  end
end

return M
