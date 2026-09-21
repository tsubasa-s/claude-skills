---
name: delegate-muse
description: 設計→Muse実装→レビューの固定フロー。Muse(Meta の Muse Code エージェント)に実装を委譲・依頼・任せる時(「museに実装させて」「実装はmuseで」「museに投げて」等)は必ずこのスキルを使う。implement.sh がworktree隔離+herdrペインでMuseを起動し、turn.sh(1ターン送信→Museのセッションログで終了検出)をバックグラウンド実行して verdict を受け取り、レビュー後 finish.sh で accept/abandon する。Delegate implementation to Muse: Claude designs and reviews, Muse implements in an isolated git worktree inside a herdr pane.
---

設計とレビューはClaude、実装はMuse(herdrペインで動く対話TUI)、機械的な手順はスクリプトに固定した
委譲フロー。delegate-codex と同じレール(spec → worktree隔離 → 監視 → レビュー → 差し戻し/受け入れ/破棄)。

- **herdr** がMuseを起動・表示する(`herdr agent start --kind muse`、指示は `herdr agent prompt`)。
  ユーザーはペインでMuseの作業をそのまま見られる。
- **ターンの終わりはMuse自身のセッションログで判定する**
  (`~/.local/share/muse/sessions/<日付>/<session>/session.jsonl` の `terminal` / 質問 / 承認イベント)。
  herdrの状態表示はMuse 1.3.0では早すぎたり誤ったりする(Gotchas参照)ので完了判定には使わない。
- 同じペイン=同じMuseセッションでターンを重ねるので、差し戻しでも前ターンの文脈は保たれる。

ユーザーレベルskill(全プロジェクト共通)。`SKILL_DIR` = `~/.claude/skills/delegate-muse`
(実体は claude-skills リポジトリへのsymlink)。全スクリプトは**対象リポジトリ内をcwdにして**呼ぶ
(Bashツールは毎回cwdが戻るので `cd <repo> && ...`)。

## 前提

```bash
test "${HERDR_ENV:-}" = 1 && herdr status   # herdrペイン内で動いていること、server running・0.9.1以上
muse --version                              # Muse Code 1.3.0 で実測
```

- Claude Code がherdrペインの外で動いていたら(`HERDR_ENV` 未設定)、implement.sh は拒否する。
  ユーザーにherdr内でClaude Codeを起動し直して会話を再開してもらう。
- Museが未ログインなら起動・ターンが失敗する。ユーザーに `! muse login` を頼む。
- モデルと reasoning effort は `~/.config/muse/settings.json` の既定。変える時だけ
  implement.sh に環境変数 `DELEGATE_MUSE_EFFORT` / `DELEGATE_MUSE_MODEL` を付ける(委譲ごとに固定)。

## 手順(この順番を崩さない)

### 1. 設計 — specファイルを書く

設計内容をspecファイルに書く(絶対パスでMuseに渡るので未コミットでよい。プロジェクトに
置き場所の慣例があればそれに従う)。必ず含めること: 作成・変更するファイルの明示的な列挙、
受け入れ条件(実行コマンドと期待結果)、やらないことの境界。曖昧さは質問ラリーになって遅くなる。
仕様が固まっていなければ先にユーザーと合意する。

`<slug>` は小文字 `[a-z0-9-]`・27文字以内。ブランチ `muse/<slug>`、worktree `.worktrees/muse-<slug>`、
herdrエージェント名 `muse-<slug>` になる。

### 2. 起動 — implement.sh

```bash
cd <repo> && ~/.claude/skills/delegate-muse/scripts/implement.sh <slug> <spec-file> [expect-path ...]
```

- `expect-path` は**リポジトリルート相対**で、完了時に存在すべき成果物ファイル(複数可)。
- worktree を現在の `HEAD` から切り、herdrペインを開いて(呼び出し元が幅160桁以上なら右、狭ければ下に分割。
  `DELEGATE_MUSE_IN=tab` で新しいタブ)`muse --trust-workspace` を起動する。フォーカスは奪わない。
- 本体ツリーの未コミット変更はMuseに見えない(spec自体は絶対パスで読むので未コミットでよい)。
- 出力は1個のJSON: `{agent, pane, branch, worktree, state_dir, next}`。Museは待機状態で、まだ何も送っていない。

### 3. 実行 — turn.sh をバックグラウンドで

```bash
# Bashツールで run_in_background: true
cd <repo> && ~/.claude/skills/delegate-muse/scripts/turn.sh <slug>
```

指示ファイル(spec読込・コミット・`QUESTION:` 規約入り)を書き、ペインに1行
「Read the file … and follow its instructions.」を送り、ターン終了(または人の入力待ち)まで
ブロックして verdict JSON を1個出す(=バックグラウンド完了通知で届く)。Monitorは不要。
**フォアグラウンドで実行しない**。

途中経過を見たい時だけ(ユーザーはペインで直接見られる):

```bash
cd <repo> && ~/.claude/skills/delegate-muse/scripts/status.sh <slug>
# {herdr_status, spinning, pending_turn, waiter_running, commits, dirty, screen}
# 作業中かどうかは spinning(ペインタイトルのスピナー)で見る。herdr_status の idle は早すぎる
```

### 4. verdict 対応

| verdict | 意味 | 対応 |
|---|---|---|
| `completed` | ターン正常終了・expect全て存在・コミット≥1・ツリーclean | 手順5へ |
| `question` | ターンは終わり、最終返答に `QUESTION:` 行がある(`questions`) | 設計者として即答: 6aの `--message` で回答。実装・コミット済みで任意の確認だけなら回答を省いて手順5へ |
| `input` | **ターンの途中で**人の入力待ち: `input`=Museの選択式質問(選択肢付き)、`approvals`=承認待ちコマンド。`screen` に画面末尾 | 6d で答えてから `turn.sh <slug> --wait` |
| `incomplete` | 正常終了だが `missing` / `dirty` / コミット無し / `head_branch` ずれ | `final_text` で原因を特定し、6aで差し戻し |
| `failed` | terminal が completed 以外(中断・エラー)、ペイン消失、送信した指示がログに現れない | `reason` と `screen` を読む。認証なら `! muse login`、ペイン消失なら6cで破棄してやり直し |

どの verdict でも `final_text` は読む(Museの報告・実行したテストが書かれている)。

### 5. レビュー

```bash
git log --oneline HEAD..muse/<slug>        # Museのコミット
git diff HEAD...muse/<slug>                # 差分本体
# + .worktrees/muse-<slug>/ 内でテスト実行・動作確認(worktreeなので本体ツリーに影響しない)
```

レビュー観点はspecの受け入れ条件。Museの報告を鵜呑みにせず、テストは自分で走らせる。
診断だけで終わらせず、必ず 6a/6b/6c のどれかで閉じる。

### 6a. 差し戻し(修正依頼・QUESTION への回答)

同じペインに次のターンを送る。再び run_in_background: true:

```bash
cd <repo> && ~/.claude/skills/delegate-muse/scripts/turn.sh <slug> --message "Review feedback: <具体的な修正指示>"
# 長文は --message-file <path>
```

「コミットしてツリーをcleanに」「曖昧なら QUESTION: で終える」はスクリプトが毎ターン自動で付ける。

### 6b. 受け入れ

```bash
cd <repo> && ~/.claude/skills/delegate-muse/scripts/finish.sh accept <slug>
```

現在ブランチに `merge --no-ff` し、Museのペインを閉じ、worktree・ブランチ・状態を削除する。
ターン待ち中・未完了ターンあり・worktreeがdirty・HEADが `muse/<slug>` 以外なら拒否する。

### 6c. 破棄

```bash
cd <repo> && ~/.claude/skills/delegate-muse/scripts/finish.sh abandon <slug>
```

待機中の turn.sh を止め、Museのペインを閉じ、worktreeとブランチを強制削除する。
Museのセッションログ自体は残る(`muse export --session <id>` で書き出せる)。

### 6d. ターン途中の入力に答える(`input` verdict)

- **選択式質問**(`input` に `question` と `options`): 設計者として答える。画面の `›` が1番目。
  `herdr agent send-keys muse-<slug> down enter` のように `down` を (番号-1) 回送って `enter`。
  選択肢に無い答えが要る時は `esc` で中断し、6a の `--message` で答えを送る(中断経路は未実測)。
- **承認待ち**(`approvals` にツールとコマンド): スコープ内(worktree内の作業)なら画面の許可選択肢を
  `send-keys` で選ぶ。スコープ外・判断がつかない時はユーザーに確認してから(人の承認ダイアログは未実測)。
- 答えたら `turn.sh <slug> --wait` をバックグラウンドで実行し、同じターンの続きを待つ。

## Gotchas(全て実測)

- **herdrの状態表示でターン終了を判定しない**(herdr 0.9.1 の Muse プロファイルは Muse 0.2.1 向け)。
  Muse 1.3.0 では: (1) 返答の後の「Double checking」(終了前の自己検証、約10秒)の間に idle になる、
  (2) Muse自身の承認ジャッジ(フッタの `Auto-review`)がコマンドを審査中の「Reviewing approval request」を
  blocked と表示する(人の入力は不要)、(3) 幅46桁のペインでは選択式質問のフッタが折り返して
  blocked を検出できず working のまま。セッションログはこの3つを正確に記録している
  (`terminal`、`user_input_prompt_requested/settled`、`approval requested → automated_review_* →
  decision_applied`)ので turn.sh はログで判定する。herdrの blocked はログが60秒止まった時だけ使う。
- **作業中かの目視はペインタイトルのスピナー**(`⠋ muse-<slug>`)。status.sh の `spinning`。
- **承認は既定のまま**(on-request + Auto-review)。worktree内のコミット等はAuto-reviewが数秒〜十数秒で
  自動承認する(人の承認ダイアログは実測では出ていない)。サンドボックスも既定(書き込みはworktree・
  そのgitストレージ・一時領域のみ)。ネットワークはMuseのプロキシ経由で通る。
- **`--trust-workspace` を固定している**。未信頼だと `AGENTS.md` がスキップされ規約が効かず、
  初回起動で信頼ダイアログが出てペインが止まる。
- **1委譲に turn.sh は1つずつ**(ロック)。別slug同士は並列でよい。並列が多い時は
  `DELEGATE_MUSE_IN=tab`(分割を重ねると幅が細る)。
- **worktreeは委譲時点の `HEAD` から切られる**。本体側の進行には追従せず、accept 時のマージで統合する。
- ペインをユーザーが閉じる・Museが落ちると以後のターンは `failed`(agent gone)。6cで破棄してやり直す。

## 検証記録

2026-09-21、herdr 0.9.1 + Muse Code 1.3.0 (muse-spark-1.3, effort low) で実測。
プローブ: `herdr agent start --kind muse` が3.9秒で idle・入力可、`agent prompt` で送った実装ターンが
コミットまで完了、herdr の idle がログの `terminal` より約9秒早いこと、Auto-review 審査中を herdr が
blocked と表示すること、選択式質問が幅46桁で検出されないこと、`down enter` で回答でき
ログに `user_input_prompt_settled` が残ること。
スクリプトでのフルサイクル(/tmp外のスクラッチrepo、AGENTS.md入り): greet を右ペイン・color を別タブで並列に
implement → turn(greet completed 60.9秒、color question)→ `--wait` での再開 → 差し戻しturn →
選択式質問の input → 回答 → `--wait` → accept / abandon(ペイン・タブが閉じることを確認)。
存在しないモデル指定で `failed`(`reason` にMuseのエラー)→ abandon も実測。
