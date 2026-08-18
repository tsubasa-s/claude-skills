#!/usr/bin/env bash
# delegate-codex — accept or abandon a Codex implementation session.
#
# Usage: finish.sh accept  <session> <slug>
#          merge codex/<slug> into the current branch, then `end` the session
#          (codex.py auto-removes the worktree once the branch is merged+clean).
#        finish.sh abandon <session> <slug>
#          `end` the session, then force-remove the worktree and branch.
set -euo pipefail

die() { echo "finish.sh: $*" >&2; exit 2; }

[[ $# -eq 3 ]] || die "usage: finish.sh accept|abandon <session> <slug>"
mode=$1; session=$2; slug=$3

repo=$(git rev-parse --show-toplevel) || die "not inside a git repository"
wt="$repo/.worktrees/codex-$slug"
branch="codex/$slug"

plugin_root=$(ls -d "$HOME"/.claude/plugins/cache/claude-code-herdr-plugin/claude-code-herdr-plugin/*/skills/claude-to-codex 2>/dev/null | sort -V | tail -1)
[[ -n ${plugin_root:-} ]] || die "claude-to-codex skill not found under ~/.claude/plugins/cache"
codex_py="$plugin_root/scripts/codex.py"

case $mode in
  accept)
    [[ -d $wt ]] || die "worktree not found: $wt"
    [[ -z $(git -C "$wt" status --porcelain) ]] \
      || die "worktree is dirty — Codex left uncommitted changes; send a follow-up asking it to commit, then retry"
    git -C "$repo" merge --no-ff "$branch" -m "merge: $branch (delegate-codex)"
    python3 "$codex_py" end --session "$session"
    ;;
  abandon)
    python3 "$codex_py" end --session "$session" || true
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$repo" branch -D "$branch" 2>/dev/null || true
    git -C "$repo" worktree prune
    echo "abandoned: $branch and its worktree removed"
    ;;
  *) die "mode must be accept or abandon" ;;
esac
