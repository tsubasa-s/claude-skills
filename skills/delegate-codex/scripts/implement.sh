#!/usr/bin/env bash
# delegate-codex — spawn Codex to implement a spec file in an isolated git worktree.
#
# Usage: implement.sh <slug> <spec-file> [expect-path ...]
#   slug         lowercase [a-z0-9-]; becomes branch codex/<slug> and
#                worktree <repo>/.worktrees/codex-<slug>
#   spec-file    path to the design/spec markdown Codex must implement
#   expect-path  repo-root-relative file(s) that must exist in the worktree
#                for completion to count as verified (repeatable)
#
# Prints ONE JSON object:
#   {session, branch, worktree, monitor: {command, timeout_ms, description}}
# Arm the Monitor tool with .monitor — the command already includes --no-close
# (the pane must survive completion so review feedback can be sent back).
set -euo pipefail

die() { echo "implement.sh: $*" >&2; exit 2; }

[[ $# -ge 2 ]] || die "usage: implement.sh <slug> <spec-file> [expect-path ...]"
slug=$1; spec=$2; shift 2

[[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lowercase [a-z0-9-]: $slug"
[[ -f $spec ]] || die "spec file not found: $spec"
spec_abs=$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")

repo=$(git rev-parse --show-toplevel) || die "not inside a git repository"

# Keep the worktree path deterministic: codex.py silently uniquifies an existing
# branch to codex/<slug>-2 (moving the worktree path with it), so refuse instead.
if git -C "$repo" show-ref --verify --quiet "refs/heads/codex/$slug"; then
  die "branch codex/$slug already exists — pick a new slug or finish.sh abandon the old one"
fi

wt="$repo/.worktrees/codex-$slug"

# pane = split the caller's tab (default). Codex gets ~half width — fine for a
# single delegation. Running several in parallel shrinks panes below the ~28-col
# threshold where codex.py's parsing breaks; use DELEGATE_CODEX_IN=tab for fleets.
mode=${DELEGATE_CODEX_IN:-pane}

plugin_root=$(ls -d "$HOME"/.claude/plugins/cache/claude-code-herdr-plugin/claude-code-herdr-plugin/*/skills/claude-to-codex 2>/dev/null | sort -V | tail -1)
[[ -n ${plugin_root:-} ]] || die "claude-to-codex skill not found under ~/.claude/plugins/cache"
codex_py="$plugin_root/scripts/codex.py"

# codex.py checks --expect with os.path.exists relative to OUR cwd, not the
# worktree — so prefix every expect path with the worktree root.
expect_flags=()
for p in "$@"; do expect_flags+=(--expect "$wt/$p"); done

task="Read $spec_abs and implement it exactly as specified. Work only inside your current directory (a dedicated git worktree). When done, commit ALL changes with a clear message so the working tree is clean. If anything in the spec is ambiguous, ask before guessing."

python3 "$codex_py" start --no-wait \
  --task "$task" \
  --slug "$slug" --in "$mode" --worktree --no-plan \
  ${expect_flags[@]+"${expect_flags[@]}"} \
| python3 -c '
import json, sys
branch, wt = sys.argv[1], sys.argv[2]
v = json.load(sys.stdin)
if not v.get("ok"):
    json.dump(v, sys.stdout, indent=2)
    sys.exit(1)
mon = v["result"]["monitor"]
mon["command"] += " --no-close"
print(json.dumps({"session": v["session"], "branch": branch, "worktree": wt,
                  "monitor": mon}, indent=2))
' "codex/$slug" "$wt"
