#!/usr/bin/env bash
# delegate-muse — give the Muse pane one turn and block until it ends or needs input.
#
# Usage: turn.sh <slug> [--message TEXT | --message-file PATH | --wait]
#   first turn       no message needed: Muse is told to implement the spec
#                    (a message, if given, is appended as extra instructions)
#   follow-up turns  --message / --message-file is required (review feedback, or
#                    answers to Muse's QUESTION: lines); same Muse session, so the
#                    context of earlier turns is kept
#   --wait           send nothing; keep waiting on the pending turn (after you
#                    answered an `input` verdict in the pane)
#
# Blocks — run it with the Bash tool's run_in_background: true. Prints ONE JSON object:
#   {verdict: completed|question|incomplete|input|failed, turn, questions, input,
#    final_text, commits, dirty, missing, head_branch, terminal, reason, screen, ...}
set -euo pipefail

die() { echo "turn.sh: $*" >&2; exit 2; }

[[ $# -ge 1 ]] || die "usage: turn.sh <slug> [--message TEXT | --message-file PATH | --wait]"
slug=$1; shift
message=""; wait_only=0
case ${1:-} in
  --message)      [[ $# -eq 2 ]] || die "--message takes exactly one argument"; message=$2 ;;
  --message-file) [[ $# -eq 2 && -f $2 ]] || die "--message-file needs an existing file"; message=$(<"$2") ;;
  --wait)         [[ $# -eq 1 ]] || die "--wait takes no argument"; wait_only=1 ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac

repo=$(git rev-parse --show-toplevel) || die "not inside a git repository"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
state="$common/delegate-muse/$slug"
[[ -f $state/state.json ]] || die "no delegation named $slug — run implement.sh first"

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]] or "")' "$state/state.json" "$1"; }
pending=$(field pending); spec=$(field spec); branch=$(field branch)
n=$(( $(field turns) + 1 ))

if [[ $wait_only -eq 1 ]]; then
  [[ -n $pending ]] || die "no pending turn to wait on for $slug"
else
  [[ -z $pending ]] || die "turn $n is still pending — answer it in the pane, then turn.sh $slug --wait"
  [[ $n -eq 1 || -n $message ]] || die "follow-up turn $n needs --message or --message-file"
fi

# One waiter per delegation. The Python waiter inherits this pid (exec) and removes the lock.
mkdir "$state/lock" 2>/dev/null \
  || die "a turn.sh is already waiting on $slug (pid $(cat "$state/lock/pid" 2>/dev/null || echo ?))"
echo $$ > "$state/lock/pid"
trap 'rm -rf "$state/lock"' EXIT   # only fires if we fail before exec

if [[ $wait_only -eq 0 ]]; then
  suffix="When done, commit ALL changes with a clear message so the working tree is clean. \
If something is ambiguous in a way that changes the result, do not guess — do what is \
unambiguous, commit it, and end your final reply with one line per open point starting with \
\"QUESTION:\". Finish with a short report: files changed, commands/tests run and their results."
  prompt="$state/turn-$n.prompt.md"
  if [[ $n -eq 1 ]]; then
    {
      echo "Read $spec and implement it exactly as specified. Work only inside your current directory"
      echo "(a dedicated git worktree on branch $branch); do not modify any other checkout."
      echo
      echo "$suffix"
      [[ -z $message ]] || printf '\nAdditional instructions:\n%s\n' "$message"
    } > "$prompt"
  else
    printf '%s\n\n%s\n' "$message" "$suffix" > "$prompt"
  fi
  exec python3 "$(dirname "$0")/_turn.py" "$state" send
fi
exec python3 "$(dirname "$0")/_turn.py" "$state" wait
