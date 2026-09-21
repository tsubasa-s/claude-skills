#!/usr/bin/env bash
# delegate-muse — accept or abandon a Muse delegation.
#
# Usage: finish.sh accept  <slug>
#          merge muse/<slug> into the current branch (--no-ff), then close the Muse
#          pane and remove the worktree, the branch and the delegation state.
#        finish.sh abandon <slug>
#          stop a waiting turn.sh if any, close the Muse pane, then force-remove the
#          worktree, the branch and the delegation state.
# The Muse session log itself stays in ~/.local/share/muse/sessions (muse export).
set -euo pipefail

die() { echo "finish.sh: $*" >&2; exit 2; }

[[ $# -eq 2 ]] || die "usage: finish.sh accept|abandon <slug>"
mode=$1; slug=$2

repo=$(git rev-parse --show-toplevel) || die "not inside a git repository"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
state="$common/delegate-muse/$slug"
wt="$repo/.worktrees/muse-$slug"
branch="muse/$slug"

field() { [[ -f $state/state.json ]] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]] or "")' "$state/state.json" "$1" || true; }
pane=$(field pane)
pending=$(field pending)

# Pane ids are never reused by herdr, so the recorded pane is ours if it still exists.
close_pane() { [[ -z $pane ]] || herdr pane close "$pane" >/dev/null 2>&1 || true; }

case $mode in
  accept)
    [[ ! -d $state/lock ]] || die "turn.sh is still waiting on $slug — let it finish first"
    [[ -z $pending ]] || die "a turn is still pending for $slug — finish it (turn.sh $slug --wait) or abandon"
    [[ -d $wt ]] || die "worktree not found: $wt"
    [[ -z $(git -C "$wt" status --porcelain) ]] \
      || die "worktree is dirty — Muse left uncommitted changes; send a follow-up turn asking it to commit, then retry"
    [[ $(git -C "$wt" rev-parse --abbrev-ref HEAD) == "$branch" ]] \
      || die "worktree HEAD is not on $branch — inspect before merging"
    git -C "$repo" merge --no-ff "$branch" -m "merge: $branch (delegate-muse)"
    close_pane
    git -C "$repo" worktree remove "$wt"
    git -C "$repo" branch -d "$branch"
    rm -rf "$state"
    echo "accepted: $branch merged; Muse pane closed; worktree, branch and state removed"
    ;;
  abandon)
    kill "$(cat "$state/lock/pid" 2>/dev/null)" 2>/dev/null || true
    close_pane
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
    git -C "$repo" branch -D "$branch" 2>/dev/null || true
    git -C "$repo" worktree prune
    rm -rf "$state"
    echo "abandoned: Muse pane closed; $branch, its worktree and state removed"
    ;;
  *) die "mode must be accept or abandon" ;;
esac
