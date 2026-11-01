# shiibar-gh 設計書

shiibar-gh は、自分が関わっている GitHub の PR について「自分が対応すべきこと」と「起きたこと」を macOS のメニューバーで知らせる個人用アプリ。画面デザインは docs/design のモックを正とする。

## 概要とスコープ

このアプリの責務は 3 つ。気づく（自分に関係する出来事が起きた）、自分が対応すべきかを見分ける、その場所へ飛ぶ。「何をどう修正するか」は Web の仕事で、アプリは詳細を持たない。

**対象**

- 自分が関わっている PR（作者、レビュアー、メンションされた、コメントした）。Issue は扱わない。
- スコープごとに扱う：登録した組織ごと、自分の個人リポジトリ、Public。1 つの一覧に混ぜない。スコープごとにメニューバーのアイコン、バッジ、背景色、通知のオン・オフを持つ。
- 画面の表記は英語だけ。GitHub にある用語は GitHub の表記のまま使用する。

**対象外**

- GitHub への書き込み（既読の同期も含めて一切しない）。
- トークン未登録の組織の非公開リポジトリ。
- 自分が参加していない PR の会話。参加とは、作者であること、またはその PR にコメントかレビューをしたことを指す。

## 画面構成

**メニューバー**。スコープごとにアイコン 1 つ（幅固定）。右上のバッジ＝Needs action の PR の数、青い点＝未読の知らせあり、三角＝注意（トークンの期限、取得の失敗、抑制中）。使用しないスコープのアイコンは設定で消せる。

**ポップオーバー**。押したスコープだけを表示する。上から：

1. 見出し：スコープ名、Updated … ago、Open in window、Refresh、Settings。トークンの期限やレート制限が近いときだけ黄色い帯。
2. タブ：**PRs**（PR ごとのカード。追加が新しい順で位置固定、出来事で動かさない）と **Activity**（全 PR の行を時間順に 1 本で。各行に PR 名を小さく添える）。並び替えはない。
3. チップ：**Needs action**（オンで絞る）、**My PRs｜Others' PRs**（どちらか一方、両方オフ＝すべて）、右端に **Show snoozed**（オンで Snooze 中の PR も表示する）。件数は表示しない。どれも前回の選択を記憶。
4. カードの列。
5. キーのヒント 1 行。

**カードの見出し（3 行）**

| 行 | 左から |
| --- | --- |
| 1 | PR の状態ラベル（Mergeable 緑／Draft 灰／Merged 紫／Closed 赤。Open は無印）、owner/repo #番号、右端に状況アイコン 3 つ |
| 2 | 作者のアバター、タイトル |
| 3 | base ← head、右端に Snooze の時計 |

状態ラベルと同じ色の縦線をカードの左端にも引く（色だけにしない）。「自分の PR」のタグはなく、アバターで分かる。

**状況アイコン 3 つ**。順番固定 Review／Checks／Base。塗りの ✓ 緑、塗りの × 赤、点線の ◌ 灰。文字は付けない。

| 列 | ✓ | ◌ | × | 値の元 |
| --- | --- | --- | --- | --- |
| Review | Approved | Review required | Changes requested | reviewDecision |
| Checks | Passed | In progress（None は空） | Failed | statusCheckRollup |
| Base | Up to date | Behind | Conflicts | mergeable / behindBy |

Mergeable は mergeStateStatus が CLEAN のときだけで、自前で計算しない。詳細（誰が、どのチェックが、何コミット）は載せず、押すと各軸の場所へ飛ぶ。この行から「誰の番か」は判断しない。自分が対応すべきかは Needs action で決まる。

**Needs action の定義**。次のどちらかを含む PR：Snooze していない未完了の Needs action の行、または自分の PR に赤い状況アイコン。この数がバッジ。自分の PR でレビュアーが未依頼なだけでは Needs action にしない（カードとして出るだけ）。

**押したときの動作**。カード内に開閉はない。行、見出し、状況アイコンは押すと Web のその場所へ。ホバーでしか表示されない操作は設けない。形で動作を区別する：丸＝状況（Web へ）、四角＝やること（切り替え）。

**Open in window**。見出しのボタンで、同じ内容を常に手前の小さなウインドウ（NSPanel）にする。スコープごとに 1 つ、位置と大きさを記憶。

## 行の種類と状態

カードの下に、その PR の出来事を行で並べる（新しい順）。行は 2 種類。「青い点＝気づいたか」と「オレンジ＝片づけたか」は独立。

| 種類 | 内容 | 見た目 | 操作 |
| --- | --- | --- | --- |
| Needs action（やること） | Review requested、Mentioned、自分が参加している PR への Bot 以外の Comment、自分のレビュースレッドへの Reply | 先頭に四角のチェックボックス、オレンジの背景。Done まで残る | チェックボックスで Done（緑の塗り、行全体が薄くなる）。もう一度押すと Not done |
| 知らせ | Reaction、Checks failed、Conflicts、Changes requested、Added to merge queue、Removed from merge queue、Mergeable、Merged、Closed、Bot の Comment | 種類のアイコン。新しい 3 件まで薄く残す | なし |

どちらの行にも左に青い点（未読）が付く。未読のメンションは本文 3 行（改行→スペース、記号を落とす）、それ以外は 1 行。

**未読の消え方は自動だけ**。役目は「気づいていない知らせがある」を言うことだけ。

- 行が画面に表示された時点で「表示済み」と記録し、ポップオーバーを閉じた（常時表示ウインドウが手前から外れた）ときに点を消す。スクロール外や絞り込みで隠れていた行は消さない。
- メニューバーの青い点はポップオーバーを開いた時点で消える。
- 手動の Mark as read／unread、一括既読はない。Web を開いたか、macOS の通知を押したかは関係しない。
- 確認していないのに消えることはあり得るが、失うのは Reaction と Bot への気づきだけ。Checks／Conflicts／Mergeable は状況アイコンとラベルに残り、やることはオレンジに残る。

状況アイコンは「今の状態」、行は「起きたことの記録」。Checks が落ちて直ればアイコンは Passed に戻り、Checks failed の行は残る。

## Snooze

Snooze は PR 単位。「この PR は翌朝まで確認しない」をアプリに伝える唯一の入力で、Done（列から除く）とも放置（今やることとして数え続ける）とも違う。目的はバッジが「今やることがある」を意味し続けること。

- カードの 3 行目右端の時計を押すと Snooze。毎朝、戻り時刻（設定、既定 09:00）にすべての Snooze を解除する。
- Snooze 中は PRs タブからも Activity からも消え、バッジに数えず、通知も鳴らさない。
- 戻るのは戻り時刻と Unsnooze の 2 つだけ。Snooze 中に新しい Needs action が来ても戻さない（その間に来たものも「確認しない」の対象。戻ったカードに青い点とオレンジが付いているので失うものはなく、遅れるだけ）。「来たら知りたい」なら Snooze しない。
- 解除された PR は列の先頭に戻る。
- Snooze 中に通知対象の出来事があった PR を、解除時にスコープごとに 1 件の通知にまとめる。押すとポップオーバーを開く。通知対象の出来事がなければ通知しない。
- チップ Show snoozed をオンにすると、Snooze 中のカードが薄く表示される。見出しに「Snoozed until Mon 09:00」と Unsnooze だけは本来の濃さで表示する。

## カードが出る・消える条件と監視期間

自分の開いている PR はずっと出る。カードが消えるのは、未読がなく未完了の Needs action もない PR のうち、閉じている PR、他の人の Draft、更新がないまま Days without updates before a PR is dropped（既定 14 日）を過ぎた他の人の開いている PR。

- 更新がなくて消えた他の人の PR に新しい出来事が付けば、また出る（先頭に）。

- Merged／Closed：行に Merged／Closed が付き（青い点）、確認すれば消える。左の縦線とラベルが Merged／Closed になり、状況アイコンは表示しない。クローズ時に Done にするのは Review requested だけ。Comment／Mentioned は Done を押すまで残り、バッジにも数える。
- 他の人の Draft：自分に用（未読・Needs action）がなければ表示しない。Ready for review になれば開いている PR として戻る。自分の Draft は表示する。
- 閉じた PR に新しい出来事が付けば未読が生じ、また出る（先頭に）。

**監視**。カードが出ている間は、クローズ後の日数に関係なく監視する。監視日数（設定、既定 3 日）は「カードが消えた時点から」数える。通知 API の Comment／Mentioned は日数に関係なく通知される。日数で外れるのは Reaction の検知。

## macOS 通知

通知するのは、Review requested、Mentioned、自分が参加している PR への Comment、自分のレビュースレッドへの Reply、自分のコメントへの Reaction（同じコメントは 1 件にまとめる）、自分の PR の状態変化（Checks failed、Conflicts、Changes requested、Removed from merge queue、Mergeable）。他の人の PR の状態、Added to merge queue は通知しない。Bot の Comment は設定（Notify／List only／Hide、既定 List only）。

- 文面はスコープ名を先頭に。オン・オフはスコープ単位。
- 不在 10 分以上のあとはまとめて 1 件。押すとポップオーバーを開く。
- 個別の通知を押すと、その場所を Web で直接開く（ポップオーバーを経由しない。青い点の状態は変更しない）。ボタン Done／Snooze を付け、カードに行かずに処理できる。
- Web を開く操作は「出来事を押す」の 1 種類（カードの行、Activity、macOS の通知、すべて同じ）。「押すとカードを選ぶ」操作は設けない。

## キーボード

↑↓ Move、⏎ Open、D Done／Not done（切り替え）、S Snooze。ポップオーバー下部にヒント 1 行。既読のキーはない（自動で消える）。両タブで同じ。

## 設定項目

タブは General／Scopes／Notifications／Watching。

| タブ | 項目 | 既定 |
| --- | --- | --- |
| General | Launch at login | on |
| General | PR status and reactions interval | 3 min |
| General | GraphQL cost cap (last hour)。近づくと間隔を延ばし、一覧に Throttled | 1500 points |
| General | API usage（REST／GraphQL の残り、定期取得 1 回のコスト） | 表示のみ |
| Scopes | Notifications token（classic PAT、notifications のみ）、SSO 承認の確認 | — |
| Scopes | スコープごとの fine-grained PAT（Public は不要）、テスト取得の結果、アイコン表示のオン・オフ、通知のオン・オフ | アイコン on、通知 on |
| Notifications | 種類ごとのオン・オフ | on |
| Notifications | Snooze の戻り時刻 | 09:00 |
| Notifications | Bot comments：Notify／List only／Hide | List only |
| Watching | Include requests to my teams | on |
| Watching | Days to keep watching after close | 3 |
| Watching | Days without updates before a PR is dropped | 14 |

## 実装方針

**構成**。デーモン、CLI、アプリの 3 つに分割する。

- デーモン（Rust）：GitHub の取得、状態（表示済み、Done、Snooze、カードの追加時刻、設定、スコープ）の保持と保存、トークン（Keychain の読み書きはデーモンだけ）。Unix ソケットで NDJSON を話し、状態の変化を接続中のクライアントに push する。
- CLI（Rust）：ソケット経由でデーモンを叩くだけのクライアント。
- アプリ（Swift）：UI（メニューバー、ポップオーバー、設定画面）と macOS 通知。CLI と同じソケットでデーモンと話す。デーモンの起動・停止・更新時の入れ替えはアプリが行う（launchd は使用しない）。

**UI**。SwiftUI。メニューバーのアイコンとポップオーバーの枠はまず MenuBarExtra で試し、バッジ付きアイコンとキーボード操作が足りなければ AppKit（NSStatusItem + NSPopover）。常時表示は NSPanel。ログイン時起動は SMAppService。

**トークン**。通知用 classic PAT 1 つ（notifications スコープ。組織は SSO 承認が必要）と、組織・個人のスコープごとの fine-grained PAT 1 つ。Public スコープは専用トークンを持たず、通知用の classic PAT で取得する（GraphQL は認証が必須。notifications スコープだけの PAT でも公開リポジトリは読める）。すべて読み取りだけ。

**API の使い分け**

| 必要なもの | 取り方 |
| --- | --- |
| どの PR が更新されたか | REST Notifications API（all=true。If-Modified-Since と X-Poll-Interval に従う）。通知は再取得の合図としてだけ使用し、reason で行の種類を決めない |
| Review requested、Mentioned、Comment、Reply、Merged／Closed、Added to／Removed from merge queue | 更新された PR の GraphQL timelineItems(since:)。nodes(ids:) でまとめて取る。行の種類は下の判定の表に従う |
| 状況アイコン、状態ラベル | GraphQL：reviewDecision、statusCheckRollup、mergeable、mergeStateStatus、isDraft、compare.behindBy。nodes(ids:) でまとめて（100 件まで） |
| 自分のコメントへの Reaction | GraphQL で viewer.issueComments と contributionsCollection.pullRequestReviewContributions の reactionGroups を定期取得し、件数の増加を検知する。監視期間内の PR の分だけ行にする |
| 対象 PR の発見 | GraphQL search（involves:@me、review-requested:@me）をスコープごとに |

**レート制限**。GraphQL のコストを rateLimit で毎回確認して、上限に近づいたら間隔を延ばして一覧に Throttled を表示する。残量は設定の General に表示。

**状態の保存**。行の「表示済み」、Done、Snooze、カードの追加時刻、設定、スコープはデーモンが SQLite に保存する（macOS 同梱の libsqlite3 にリンクする）。チップの選択とウインドウの位置は画面の状態なので、アプリが UserDefaults に保存する。GitHub 側には何も書き込まない。トークンは DB に保存せず Keychain に保存する。

**DB を読めないとき**。デーモンは DB ファイルを別名で退避し、空の状態で起動する。退避したファイルは削除しない。ポップオーバーに黄色い帯「Couldn't read saved state · Done and Snooze were reset」を表示する。Done と Snooze は GitHub から復元できないため、起動を止めない。

**fine-grained PAT の権限**（スコープごと。All repositories で発行）

| 権限 | 用途 |
| --- | --- |
| Pull requests: Read | PR、レビュー、コメント、reviewDecision |
| Contents: Read | compare（behindBy）、mergeable |
| Checks: Read、Commit statuses: Read | statusCheckRollup |
| Members: Read（組織のみ） | チーム宛てのレビュー依頼の判定 |
| 未確認 | マージキュー（mergeQueueEntry、タイムラインのイベント）。登録時のテスト取得で確かめ、足りなければ設定画面に表示する |

**reason を判定に使用しない理由**。reason は「なぜ自分に通知されるか」を表すスレッド単位の値で、起きた出来事を表さない。一度 mention になったスレッドは、その後メンションされなくても mention のままになる。

**PR の識別**。鍵は GraphQL の node id。通知 API は repo と number しか持たないので、初めて検出した PR は repository(owner, name){ pullRequest(number){ id } } で id を引き、repo#number → id の対応を記憶する。search（involves:@me）の結果と通知の PR は id で比較して同じ PR と判定する。

**Needs action の判定**

| 行 | 判定 |
| --- | --- |
| Review requested | REVIEW_REQUESTED_EVENT の requestedReviewer が自分。チーム宛ては自分が属するチームか（Members: Read）。設定でチーム宛てを含めない選択あり |
| Mentioned | MENTIONED_EVENT の actor が自分（actor はメンションされた人） |
| Comment | ISSUE_COMMENT の author が Bot でも自分でもなく、自分がその PR に参加している |
| Reply | PULL_REQUEST_REVIEW_THREAD の comments で、自分以外のコメントが属するスレッドの最初のコメントの author が自分 |
| Merged／Closed | MERGED_EVENT／CLOSED_EVENT（自分の操作かは問わない） |

同じ出来事が Mentioned と Comment の両方に該当するときは Mentioned の行だけを生成する。

**選択とキー**。選択は PRs タブでは「カードの見出し」と「行」を上から順に、Activity では行だけを移る。見出しで ⏎ は PR を開く、S はその PR を Snooze、D は何もしない。行で ⏎ はその場所を開く、D は Done の切り替え（Needs action の行のみ）、S はその行の PR を Snooze。

**Activity に表示する行**。PRs タブに今出ているカードの行だけ。絞り込み（Needs action、My PRs、Others' PRs、Show snoozed）は両タブに同じように適用する。

**初回、失敗、空**

| 状態 | 見せ方 |
| --- | --- |
| トークン未設定 | ポップオーバーに「Add a token in Settings」と Settings ボタンだけ。設定は Scopes タブで開く |
| 取得の失敗 | アイコンに三角。ポップオーバーに黄色い帯「Couldn't reach GitHub · retrying in N min」。前回の内容は残す |
| レート制限が上限に近い | 帯に「Throttled」。間隔を延ばす |
| カードが 0 件 | 「Nothing needs you」。絞り込みで 0 件なら「Nothing matches」 |
| Activity が 0 件 | 「No activity」 |

**通知 API の取り方**。If-Modified-Since と X-Poll-Interval に従う。50 件ずつ、since は前回の最新。既読の同期はしない（GitHub 側の未読は触らない）。

**CLI（AI 連携）**。`shiibar-gh` コマンドで、ポップオーバーと設定でできる操作をすべて持つ。アプリのローカル状態を読み書きするだけで、GitHub には書き込まない。AI エージェントは Bash から呼ぶ（--help と --json で足りる。CLI の存在と主な使い方は CLAUDE.md に数行記述する）。MCP は作成しない。

| コマンド | 動作 |
| --- | --- |
| list [--scope] [--needs-action] [--mine｜--others] [--snoozed] [--json] | PRs タブと同じ列を出力する |
| status \<pr\> | 状態ラベルと Review／Checks／Base |
| activity [--scope] [--json] | Activity タブと同じ流れ |
| done \<row\> / undone \<row\> | Done の切り替え |
| snooze \<pr\> / unsnooze \<pr\> | PR 単位の Snooze |
| refresh | 今すぐ取得 |
| open \<pr｜row\> | その場所の URL を出力する（開くのは呼び元） |
| config get \<key\> / config set \<key\> \<value\> | 設定項目の読み書き（設定画面と同じ項目） |
| scope list / scope add \<org\> / scope remove \<org\> / scope icon \<scope\> on\|off | スコープの登録とアイコンの表示 |
| token set notifications / token set \<scope\> / token test \<scope\> | トークンの登録（標準入力から読み取る。引数には渡さない）とテスト取得 |

`<pr>` は owner/repo#number、`<row>` は list／activity が出力する id。

## デーモンの仕様

### ワイヤ形式

Unix ソケットの NDJSON。1 接続 1 要求 1 応答。`subscribe` だけは接続を維持する。応答は `{"ok":true,...}` または `{"ok":false,"error":"..."}`。クライアントは未知の `event` とフィールドを無視する。時刻は epoch 秒。

| cmd | 引数 | 応答 |
| --- | --- | --- |
| `list` | scope、needs_action、mine、others、snoozed | `cards` |
| `activity` | list と同じ | `rows` |
| `status` | pr | `card` |
| `seen` | row_ids | — |
| `popover_opened` | scope | — |
| `popover_closed` | scope | — |
| `done`／`undone` | row | — |
| `snooze`／`unsnooze` | pr | — |
| `refresh` | scope（省略可） | — |
| `open` | pr または row | `url` |
| `config_get`／`config_set` | key、value | `value` |
| `scope_list`／`scope_add`／`scope_remove` | org | `scopes` |
| `scope_icon`／`scope_notify` | scope、on | — |
| `token_set` | target、token | — |
| `token_test` | scope | `results` |
| `subscribe` | — | 下の event の流れ |
| `info` | — | `version`、`started_at` |
| `shutdown` | — | 応答後に終了 |

`subscribe` は最初に `{"event":"snapshot","scopes":[...]}` を送る。以降は `{"event":"scope_changed","scope":{...}}` と `{"event":"notify","notification":{...}}` を送る。

トークンは `token_set` の中にだけ現れる。デーモンはこの要求をログに出力しない。

### CLI の終了コード

0 成功、1 接続エラーまたは内部エラー（デーモン不在を含む）、2 該当なし。

### 行の状態遷移

行の鍵は GitHub の出来事の node id。同じ出来事から行を二重に生成しない。

| 契機 | unread | seen_pending | done |
| --- | --- | --- | --- |
| 行の生成 | 立てる | — | 未完了 |
| `seen`（行が画面に表示された） | — | 立てる | — |
| `popover_closed` | seen_pending の行で下ろす | 下ろす | — |
| `done` | — | — | 完了 |
| `undone` | — | — | 未完了 |
| PR のクローズ | — | — | Review requested の行だけ完了 |

`done` と `undone` の対象は Needs action の行だけで、知らせの行は変化しない。知らせの行は新しい 3 件を残す。未読の行は 3 件を超えても残す。

### カードの状態

- 表示の判定は次の順で行う。Snooze 中は Show snoozed がオンのときだけ表示する。それ以外は、未読または未完了の Needs action があれば表示する。残りは「カードが出る・消える条件と監視期間」に従う。
- 並びは `sort_at` の降順。`sort_at` はカードの追加時に設定し、Snooze から戻ったとき、閉じた PR に新しい出来事が付いたとき、消えた PR が再び出たときだけ更新する。
- Snooze は PR ごとの有無だけを保存し、戻る時刻を PR ごとに保存しない。解除はローカル時刻の Return time に行う。「Snoozed until」の表示は次の Return time から求める。Return time を変更すると、Snooze 中のすべての PR に反映する。

### 通知の判定

デーモンが行の生成時に通知の要否を判定し、結果を行に保存する。アプリの再起動で再通知しない。Snooze 中の PR の行は個別に通知せず、解除時のまとめ通知の対象として記録する。種類またはスコープの通知がオフの行はまとめ通知に含めない。Mac のスリープ中に Return time を過ぎた場合は、復帰時に解除とまとめ通知を 1 回だけ行う。「不在 10 分以上」はアプリが判定し、まとめ通知はスコープごとに 1 件とする。

### 定数

| 定数 | 値 |
| --- | --- |
| 状態ディレクトリ | `~/.local/state/shiibar-gh/`（`SHIIBAR_GH_STATE_DIR` で変更） |
| ログレベル | info（`SHIIBAR_GH_LOG` で変更） |
| アプリの再接続 | 1 秒から倍々、上限 30 秒 |
| 状態ディレクトリの権限 | ディレクトリ 0700、DB 0600 |

## 未決

- [ ] マージキューの取得に fine-grained PAT のどの権限が必要か（登録時のテスト取得で確認。他の権限は実装方針の表に記載）
- [ ] チームへのメンションを MENTIONED_EVENT で判定できるか（公開 PR で確認できたのは個人へのメンションだけ）
