---
name: delegate-codex
description: 設計→Codex実装→レビューの固定フロー。Codexに実装を委譲・依頼・任せる時(「codexに実装させて」「実装はcodexで」等)は必ずこのスキルを使う。implement.sh でworktree隔離のCodexを起動し、Monitorで監視、レビュー後 finish.sh で accept/abandon する。Delegate implementation to Codex: Claude designs and reviews, Codex implements in an isolated git worktree.
---

設計とレビューはClaude、実装はCodex(herdrペイン)、機械的な手順はスクリプトに固定した委譲フロー。
herdrプラグインの claude-to-codex スキル(`codex.py`)のラッパーであり、フラグの組み立てを
`scripts/implement.sh` / `scripts/finish.sh` に固定することで毎回同じレールに乗せる。

ユーザーレベルskill(全プロジェクト共通)。`SKILL_DIR` = `~/.claude/skills/delegate-codex`
(実体は claude-skills リポジトリへのsymlink)。作業対象のパスはカレントリポジトリのルート相対。

## 前提

```bash
herdr status   # server: running であること。落ちていたらユーザーに伝える(Bashからは起動不可)
```

claude-code-herdr-plugin がインストール済みであること(スクリプトが
`~/.claude/plugins/cache/.../skills/claude-to-codex/scripts/codex.py` を自動解決する)。

## 手順(この順番を崩さない)

### 1. 設計 — specファイルを書く

設計内容をspecファイルに書く(絶対パスでCodexに渡るので未コミットでよい。プロジェクトに
置き場所の慣例があればそれに従う — 例: rightsmatch は `docs/design/delegate/<slug>.md`)。
必ず含めること: 作成・変更するファイルの明示的な列挙、受け入れ条件、やらないことの境界。
曖昧さはCodexからの質問ラリーになって遅くなる。仕様が固まっていない場合は先にユーザーと合意する。

`<slug>` は小文字 `[a-z0-9-]`。ブランチ `codex/<slug>` とworktree `.worktrees/codex-<slug>` の名前になる。

### 2. 起動 — implement.sh

```bash
~/.claude/skills/delegate-codex/scripts/implement.sh <slug> <spec-file> [expect-path ...]
```

- `expect-path` は**リポジトリルート相対**で、完了時に存在すべき成果物ファイル(複数可)。
  specの「作成するファイル」列挙と一致させる。スクリプトがworktreeパスに変換して渡す。
- 固定フラグ: `--in pane --worktree --no-plan --no-wait`(Codexは `codex/<slug>` ブランチの
  独立worktreeで作業。作業ツリーは汚れない)。モードのみ環境変数 `DELEGATE_CODEX_IN=tab|space`
  で上書き可(既定 pane)
- 出力は1個のJSON: `{session, branch, worktree, monitor}`

### 3. 監視 — Monitorツールを張る

出力JSONの `.monitor` をそのままMonitorツールに渡す(`command` / `timeout_ms` /
`persistent: false`)。`command` には `--no-close` が付与済み(完了後もペインを残し、
差し戻しできるようにするため)。

### 4. イベント対応

| イベント | 対応 |
|---|---|
| `awaiting_clarification` | 設計者として即答: `python3 <codex.py> reply --session <id> --text "..." --no-wait`(watchが次状態を報告する) |
| `permission_gate` → `auto_approved` | 何もしない(watchが自動承認) |
| `completed` / `marker_verified` | **watchはここで終了する**(`--no-close`はペインを残すだけ)。手順5へ |
| `completed` / `marker_unverified` | 約束された成果物が無い。`transcript_tail` を読み、手順6aで差し戻し |
| `exited` / `pane_gone` | セッション消失。再度 implement.sh から(旧ブランチは finish.sh abandon で掃除) |

### 5. レビュー

```bash
git log --oneline HEAD..codex/<slug>        # Codexのコミット(コミットが無い=ツリーがdirtyならacceptは失敗する)
git diff HEAD...codex/<slug>                # 差分本体
# + .worktrees/codex-<slug>/ 内でテスト実行・動作確認(worktreeなので本体ツリーに影響しない)
```

レビュー観点はspecの受け入れ条件。診断だけで終わらせず、必ず 6a/6b/6c のどれかで閉じる。

### 6a. 差し戻し(修正依頼)

watchは完了時点で終了しているので、差し戻しは**ブロッキングのsendをバックグラウンドで**実行し、
1回分の検証結果(verdict JSON)を通知で受け取る:

```bash
# Bashツールで run_in_background: true にして実行
python3 <codex.py> send --session <id> \
  --message "Review feedback: <具体的な修正指示>. Commit the change so the tree stays clean." \
  --expect <worktree>/<成果物>
```

verdictが `completed` になったら手順5に戻る。

### 6b. 受け入れ

```bash
~/.claude/skills/delegate-codex/scripts/finish.sh accept <session> <slug>
```

現在ブランチに `merge --no-ff` してから `end`。マージ済み+クリーンなので codex.py が
worktree・ブランチ・ペインを全て自動削除する。worktreeがdirty(Codex未コミット)なら
マージ前に失敗するので、6aで「commit your changes」を送ってから再実行。

### 6c. 破棄

```bash
~/.claude/skills/delegate-codex/scripts/finish.sh abandon <session> <slug>
```

セッションを閉じ(死んでいても可)、worktreeとブランチを強制削除する。

## Gotchas(全て実測)

- **`--expect` は呼び出し元cwd基準で判定される**(worktree内ではない)。implement.sh が
  worktreeプレフィックスを自動付与するので、渡すのはリポジトリルート相対パスでよい。
  6a の `send` では自分で `<worktree>/` を付けること。
- **watchは `completed` で必ず終了する**。`--no-close` はペインを残すだけで、watchの寿命は
  延ばさない。差し戻しごとに watch を張り直すのではなく、ブロッキング send 1回=verdict 1個で回す。
- **既存ブランチ `codex/<slug>` があると codex.py は黙って `codex/<slug>-2` にリネームし
  worktreeパスもズレる**。implement.sh はこれを検知して拒否する — 新しいslugを使うか
  `finish.sh abandon` で旧セッションを掃除してから。
- **Codexがコミットしないと accept が失敗する**(worktree自動削除の条件が「マージ済み+クリーン」
  のため)。タスク文に commit 指示は固定済みだが、守られなかったら send で催促。
- **既定は `--in pane`**(呼び出し元タブを右分割、Codexは非フォーカスで起動)。1並列なら
  ~半幅で問題ないが、**複数並列は禁物**: 分割のたびに幅が半減し、~28桁を切るとCodex出力の
  パース(プラン/メニュー検出)が壊れる。並列で走らせる時は `DELEGATE_CODEX_IN=tab` を付ける。
  ペイン/タブは accept/abandon で自動的に閉じる。
- accept 後は `end` がブランチも削除する(マージ済みのため)。ブランチを残したい場合は
  finish.sh を使わず手動で `end --keep` 相当の運用にする。

## 検証記録

2026-07-05、スクラッチrepoでフルサイクル実測済み: implement.sh → watch(completed/
marker_verified)→ レビュー → send差し戻し(goodbye追加、completed)→ finish.sh accept
(merge + worktree/branch自動削除)。abandon はdirty worktree+死んだセッションIDで実測。
フルサイクルは `--in tab` で実測、pane モードは spawn→watch→自動クローズを別タスクで実測
(既定を pane に変更したのは同日)。
