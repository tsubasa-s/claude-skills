# claude-skills

自分用の Claude Code スキル置き場。各 PC には symlink で配備する。

## セットアップ(新しい PC)

```bash
git clone https://github.com/tsubasa-s/claude-skills.git
cd claude-skills && ./install.sh
```

`install.sh` が `skills/` 以下の各スキルを `~/.claude/skills/<name>` に symlink する
(冪等。既存の非 symlink スキルには触らない)。以後の更新は clone した場所で `git pull`
するだけ(symlink なので再インストール不要。スキルを追加した時だけ `./install.sh` を再実行)。

## スキルの追加

`skills/<name>/SKILL.md`(+必要なら `scripts/` 等)を作って `./install.sh` を再実行し、
commit & push。

## 収録スキル

- **delegate-codex** — 設計→Codex 実装→レビューの委譲フロー(worktree 隔離)。
  前提: [claude-code-herdr-plugin](https://github.com/yigitkonur/claude-code-herdr-plugin)
  がインストール済みで、herdr server が起動していること。
- **delegate-muse** — 設計→Muse(Muse Code)実装→レビューの委譲フロー(worktree 隔離)。
  Muse は herdr ペインで動き、ターンの終わりは Muse のセッションログで判定する。
  前提: herdr 0.9.1 以上のペイン内で Claude Code が動いていること、`muse` がログイン済みであること。
