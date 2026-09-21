#!/usr/bin/env bash
# delegate-muse — open Muse in a herdr pane, working in an isolated git worktree.
#
# Usage: implement.sh <slug> <spec-file> [expect-path ...]
#   slug         lowercase [a-z0-9-], at most 27 chars; becomes branch muse/<slug>,
#                worktree <repo>/.worktrees/muse-<slug> and herdr agent muse-<slug>
#   spec-file    path to the design/spec markdown Muse must implement
#   expect-path  repo-root-relative file(s) that must exist in the worktree
#                for a turn to count as completed (repeatable)
#
# Must run inside a herdr pane. Muse starts idle in a new pane (right of the caller,
# or below it when the caller is narrow; DELEGATE_MUSE_IN=tab for a new tab) —
# nothing is sent yet. Prints ONE JSON object:
#   {agent, pane, branch, worktree, state_dir, next}
# Run .next (turn.sh <slug>) with the Bash tool's run_in_background: true.
# Optional env: DELEGATE_MUSE_EFFORT (reasoning effort), DELEGATE_MUSE_MODEL.
set -euo pipefail

die() { echo "implement.sh: $*" >&2; exit 2; }

[[ $# -ge 2 ]] || die "usage: implement.sh <slug> <spec-file> [expect-path ...]"
slug=$1; spec=$2; shift 2

[[ ${HERDR_ENV:-} == 1 && -n ${HERDR_PANE_ID:-} ]] \
  || die "not running inside a herdr pane — start Claude Code inside herdr, then retry"
[[ $slug =~ ^[a-z0-9][a-z0-9-]{0,26}$ ]] || die "slug must be lowercase [a-z0-9-], at most 27 chars: $slug"
[[ -f $spec ]] || die "spec file not found: $spec"
spec_abs=$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")
command -v muse >/dev/null || die "muse not found on PATH"

repo=$(git rev-parse --show-toplevel) || die "not inside a git repository"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
branch="muse/$slug"
wt="$repo/.worktrees/muse-$slug"
state="$common/delegate-muse/$slug"
agent="muse-$slug"

if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  die "branch $branch already exists — pick a new slug or finish.sh abandon $slug"
fi
[[ ! -e $wt ]] || die "worktree path already exists: $wt — finish.sh abandon $slug first"
[[ ! -e $state ]] || die "stale state for $slug at $state — finish.sh abandon $slug first"

# Keep .worktrees/ out of the caller's `git status` when the repo does not ignore it.
if ! git -C "$repo" check-ignore -q "$wt"; then
  mkdir -p "$common/info"
  echo ".worktrees/" >> "$common/info/exclude"
fi

git -C "$repo" worktree add -q -b "$branch" "$wt" HEAD
mkdir -p "$state"

undo() {
  [[ -z ${pane:-} ]] || herdr pane close "$pane" >/dev/null 2>&1 || true
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  rm -rf "$state"
}
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d)' "$1"; }

# Where Muse appears. A right split halves the caller's width; below that the pane
# is hard to read, so a narrow caller splits downward instead.
mode=${DELEGATE_MUSE_IN:-pane}
case $mode in
  pane)
    width=$(herdr pane layout --pane "$HERDR_PANE_ID" | python3 -c '
import json, os, sys
for p in json.load(sys.stdin)["result"]["layout"]["panes"]:
    if p["pane_id"] == os.environ["HERDR_PANE_ID"]:
        print(p["rect"]["width"])')
    dir=right; [[ ${width:-0} -ge 160 ]] || dir=down
    pane=$(herdr pane split --current --direction "$dir" --cwd "$wt" --no-focus | jget result.pane.pane_id) \
      || { undo; die "herdr pane split failed"; }
    ;;
  tab)
    pane=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$wt" --label "$agent" --no-focus \
           | jget result.root_pane.pane_id) || { undo; die "herdr tab create failed"; }
    ;;
  *) undo; die "DELEGATE_MUSE_IN must be pane or tab" ;;
esac

# --trust-workspace: load the worktree's AGENTS.md (skipped with a warning otherwise) and
# skip the first-launch trust dialog. Approval and the sandbox stay at their defaults.
args=(--trust-workspace)
[[ -z ${DELEGATE_MUSE_EFFORT:-} ]] || args+=(--reasoning-effort "$DELEGATE_MUSE_EFFORT")
[[ -z ${DELEGATE_MUSE_MODEL:-} ]]  || args+=(--model "$DELEGATE_MUSE_MODEL")
if ! out=$(herdr agent start "$agent" --kind muse --pane "$pane" --timeout 60000 -- "${args[@]}" 2>&1); then
  undo; die "herdr agent start failed: $out"
fi

skill_dir=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$state/state.json" "$slug" "$agent" "$pane" "$branch" "$wt" "$repo" \
  "$(git -C "$repo" rev-parse HEAD)" "$spec_abs" "$skill_dir" "$@" <<'EOF'
import json, sys
path, slug, agent, pane, branch, wt, repo, base, spec, skill_dir, *expect = sys.argv[1:]
state = {"slug": slug, "agent": agent, "pane": pane, "branch": branch, "worktree": wt,
         "repo": repo, "base": base, "spec": spec, "expect": expect, "turns": 0,
         "session_log": None, "pending": None}
with open(path, "w") as f:
    json.dump(state, f, indent=2)
print(json.dumps({"agent": agent, "pane": pane, "branch": branch, "worktree": wt,
                  "state_dir": path.rsplit("/", 1)[0],
                  "next": f"{skill_dir}/scripts/turn.sh {slug}"}, indent=2))
EOF
