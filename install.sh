#!/usr/bin/env bash
# claude-skills — symlink every skill under skills/ into ~/.claude/skills/.
# Idempotent: re-running refreshes existing links. Skills already present in
# ~/.claude/skills that are NOT symlinks (installed by other means) are left
# untouched and reported.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")" && pwd)
target_dir="$HOME/.claude/skills"
mkdir -p "$target_dir"

for src in "$repo_dir"/skills/*/; do
  src=${src%/}
  name=$(basename "$src")
  dst="$target_dir/$name"
  if [[ -e $dst && ! -L $dst ]]; then
    echo "skip: $dst exists and is not a symlink — remove it manually if this repo should manage it" >&2
    continue
  fi
  ln -sfn "$src" "$dst"
  echo "linked: $dst -> $src"
done
