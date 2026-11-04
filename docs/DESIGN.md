# shiibar-gh 設計書

shiibar-gh は、自分が関わっている GitHub の PR について「自分が対応すべきこと」と「起きたこと」を macOS のメニューバーで知らせる個人用アプリ。画面デザインは docs/design のモックを正とする。

## 概要とスコープ

このアプリの責務は 3 つ。気づく（自分に関係する出来事が起きた）、自分が対応すべきかを見分ける、その場所へ飛ぶ。「何をどう修正するか」は Web の仕事で、アプリは詳細を持たない。

**対象**

- 自分が関わっている PR（作者、レビュアー、メンションされた、コメントした）。Issue は扱わない。
- スコープごとに扱う：登録した owner（組織または個人）ごとと Public。1 つの一覧に混ぜない。スコープごとにメニューバーのアイコン、バッジ、背景色、通知のオン・オフを持つ。
- 画面の表記は英語だけ。GitHub にある用語は GitHub の表記のまま使用する。

**対象外**

- GitHub への書き込み（既読の同期も含めて一切しない）。
- トークン未登録の owner の非公開リポジトリ。
- 他の人の PR の会話のコメント。ただし、自分へのメンションと、Reply の対象のスレッドへの返信は対象にする（「行の種類と状態」）。

## 画面構成

**メニューバー**。スコープごとにアイコン 1 つ（幅固定）。右上のバッジ＝Needs action の PR の数、青い点＝新しい出来事あり、三角＝注意（トークンの期限、取得の失敗、上限による取得の停止）。disabled のスコープのアイコンは表示しない。

**ポップオーバー**。押したスコープだけを表示する。上から：

1. 見出し：スコープ名、Updated … ago、Open in window、Refresh、Settings。トークンの期限やレート制限が近いときだけ黄色い帯。
2. タブ：**PRs**（PR ごとのカード。追加が新しい順で位置固定、出来事で動かさない）と **Activity**（全 PR の行を新しい順に 1 本で。各行に PR 名を小さく添える）。並び替えはない。
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
| Review | Approved | Review required | Changes requested | reviewDecision（null なら最新のレビューから求める） |
| Checks | Passed | In progress（None は空） | Failed | statusCheckRollup |
| Base | Up to date | Behind | Conflicts | mergeable / behindBy |

Base は、behindBy を取得できなければ Conflicts または空とする。mergeable が UNKNOWN なら前回の値を保つ。

Mergeable は mergeStateStatus が CLEAN のときだけで、自前で計算しない。詳細（誰が、どのチェックが、何コミット）は載せず、押すと各軸の場所へ飛ぶ。飛び先は、Review と Base が PR のページ、Checks が PR の Checks のページ（`/checks`）である。この行から「誰の番か」は判断しない。自分が対応すべきかは Needs action で決まる。

**Needs action の定義**。Snooze していない PR のうち、未完了の Needs action の行を含む PR、または赤い状況アイコンを持つ自分の開いている PR。この数がバッジ。自分の PR でレビュアーが未依頼なだけでは Needs action にしない（カードとして出るだけ）。

**押したときの動作**。カード内に開閉はない。行、見出し、状況アイコンは押すと Web のその場所へ。ホバーでしか表示されない操作は設けない。形で動作を区別する：丸＝状況（Web へ）、四角＝やること（切り替え）。

**Open in window**。見出しのボタンで、同じ内容を常に手前の小さなウインドウ（NSPanel）にする。スコープごとに 1 つ、位置と大きさを記憶。

## 行の種類と状態

カードの下に、その PR の出来事を行で並べる（新しい順）。出来事 1 件が 1 行で、macOS の通知は行から生成する出力である（複数の行を 1 件の通知にまとめることがある）。行は 2 種類。「青い点＝気づいたか」と「オレンジ＝片づけたか」は独立。

| 種類 | 内容 | 見た目 | 操作 |
| --- | --- | --- | --- |
| Needs action（やること） | Review requested、Mentioned、自分の PR への Bot 以外の Comment、自分がコメントしたスレッドへの Reply、スレッドで自分がメンションされたあとの Reply | 先頭に四角のチェックボックス、オレンジの背景。Done まで残る | チェックボックスで Done（緑の塗り、行全体が薄くなる）。もう一度押すと Not done |
| イベント | Reaction、Checks failed、Conflicts、Changes requested、Mergeable（この 4 つの状態変化は自分の PR だけ）、Added to merge queue、Removed from merge queue、Merged、Closed、Bot の Comment | 種類のアイコン。既読になると薄く表示する | なし |

**Comment と Reply の対象**。Comment の行は、自分の PR に他の人が投稿した会話のコメント、レビューの本文、インラインコメントから、1 コメントにつき 1 行を生成する。Bot が投稿したものは、会話のコメント、レビューの本文、インラインコメントのいずれも Bot の Comment の行にし、Bot comments の設定に従う（Needs action にしない）。Approve のレビューの本文も含めて、すべて Needs action とする。本文付きで変更を求めるレビューは、Changes requested の行と Comment の行の両方を残す。他の人の PR の会話のコメントは行にしない。Reply の行は、自分がコメントしたスレッドへの返信と、スレッドで自分がメンションされたあとの返信から生成し、どの PR でも対象にする。ここでのスレッドは、コードの行に付くレビューのスレッドを指す。Comment と Reply の両方に該当するコメント（自分の PR の、自分がコメントしたスレッドへの返信）は、Reply の行だけを生成する。Mentioned と Reply の両方に該当するコメントは、Mentioned の行だけを生成する。Bot の投稿は、自分のスレッドへの返信でも自分へのメンションでも、常に Bot の Comment の行にする（Bot comments の設定に従い、Needs action にしない）。

どちらの行にも左に青い点（未読）が付く。Bot comments が Hide の行は未読に数えず、カードの表示、Needs action、残す行の整理にも影響しない。List only または Notify に戻すと既読で表示する。未読のメンションは本文 3 行（改行→スペース、記号を落とす）、それ以外は 1 行。

**未読の消え方は自動だけ**。役目は「気づいていない出来事がある」を示すことだけ。

- 行が画面に表示された時点で「表示済み」と記録し、ポップオーバーを閉じた（常時表示ウインドウが手前から外れた）ときに点を消す。スクロール外や絞り込みで隠れていた行は消さない。
- メニューバーの青い点はポップオーバーを開いた時点で消える。Snooze 中の行と Bot comments が Hide の行では付けず、Snooze の解除時（手動の Unsnooze を含む）に未読の行があれば付ける。ポップオーバーまたは常時表示ウインドウを開いている間は、新着でも解除でも付けず、閉じたときに未読の行が残っていても付けない。
- 手動の Mark as read／unread、一括既読はない。Web を開いたか、macOS の通知を押したかは関係しない。
- 確認していないのに消えることはあり得るが、失うのは Reaction と Bot への気づきだけ。Checks／Conflicts／Mergeable は状況アイコンとラベルに残り、やることはオレンジに残る。

状況アイコンは「今の状態」、行は「起きたことの記録」。Checks が落ちて直ればアイコンは Passed に戻り、Checks failed の行は残る。再び落ちれば新しい行を生成する。

**Review requested の行**。今もやることかは、その PR の Review requested の行のうち最新の行であり、PR が開いていて、今も自分または自分のチームにレビューが依頼されているかで判断する。Done の値は変更しない。条件から外れた行はバッジに数えず、オレンジとチェックボックスを表示せず、既読のイベントの行と同じ薄い表示にして整理の対象にする。未読の行は青い点を残し、通常の規則で既読にする。PR が再び開かれると、整理済みの行も含めてやることに戻す。再び依頼された場合は新しい行を生成する。

**Include requests to my teams**。チーム宛てのレビュー依頼は、設定に関係なく記録する。オフの間は、チーム宛ての Review requested の行を表示せず、未読、バッジ、通知の対象にしない（Bot comments の Hide と同じ扱い）。オンに戻すと、オフの間に記録した行を既読で表示し、さかのぼって通知しない。今もチームに依頼が続いている行は、上の規則のとおりやることになる。

**残す行の数**。未読の行と未完了の Needs action の行はすべて残す。既読のイベントの行と Done の行は、合わせて PR ごとに新しい 3 件を残す。整理はポップオーバーを閉じたとき（常時表示ウインドウが手前から外れたとき）に行う。整理した行は表示しないが内部に記録を残し、再取得で復活させない。Activity も同じ行を表示する。

**Reaction の行**。自分のコメント（会話のコメント、レビューの本文、レビューコメント、PR の本文）の Reaction を種類ごとの件数で検知し、増えた種類ごとに 1 行を生成する。1 回の取得で同じ種類が複数増えた場合は 1 行で件数を表示する（`👍3`）。行の時刻は検知した時刻とする。件数が減っただけのときは行を生成しない。Reaction を削除して再度付けると新しい出来事として扱う。自分が付けた Reaction は件数から除く。監視の外で増えた分は行にせず、監視が戻った時点の件数を基準にする。監視中の PR の自分のコメントは、初めて集めたときの件数を基準にする。ただし、そのスコープの前回の取得より後に投稿されたコメントは 0 を基準にする。

**状態変化の行**。Checks failed、Conflicts、Changes requested、Mergeable の行は、開いている自分の PR の値が変化したときに生成する。Checks failed は `failed` 以外の値から `failed` に、Conflicts は `conflicts` 以外の値から `conflicts` に、Changes requested は `changes_requested` 以外の値から `changes_requested` に、Mergeable は偽から真に変化した場合である。すでに `failed` の PR で別のチェックが落ちた場合と、すでに `changes_requested` の PR で別のレビュアーが変更を求めた場合は、値が変化しないので行を生成しない。PR を初めて検出した時点では前回の値がないので行を生成しない。行の時刻は検知した時刻とする。本文は、Checks failed が最初に失敗したチェックの名前とほかに失敗したチェックの数（`+N`）、Changes requested が最初のレビュアーのログイン名とほかに変更を求めたレビュアーの数（`+N`）で、Conflicts と Mergeable は本文を持たない。押すと開く場所は、Checks failed が Checks、Conflicts が Base、Changes requested が Review、Mergeable が PR のページである。失敗したチェックは、完了した GitHub Actions の job のうち結果が success、neutral、skipped 以外のものと、状態が FAILURE または ERROR の Commit status である。完了していない job と、PENDING または EXPECTED の Commit status は失敗に含めない。名前を取得できなければ本文を持たない。

**監視開始より前の出来事**。スコープの監視開始時刻は、スコープを追加した時点、enabled にした時点、DB を空の状態で起動した時点である。この時刻より前の出来事は行にしない。監視開始時刻を設定するときは、そのスコープの PR の前回の値と Reaction の基準値を破棄する。出来事は、そのスコープで最後に取得に成功した時刻から 5 分さかのぼった時刻（監視開始時刻より前にはしない）以降のものを取得して行にする。PR を初めて検出した場合も同じで、それより前の出来事は行にしない。アプリの停止中に起きた出来事は、この時刻より後なので行になる。例外として、今も続いているレビュー依頼は、時刻に関係なく未読の Needs action の行にする（取得の範囲が制限するのは、ほかの出来事の取得だけである）。この行は、依頼が監視開始時刻以降なら通知し、監視開始時刻より前なら通知しない。

## Snooze

Snooze は PR 単位。「この PR は翌朝まで確認しない」をアプリに伝える唯一の入力で、Done（列から除く）とも放置（今やることとして数え続ける）とも違う。目的はバッジが「今やることがある」を意味し続けること。

- カードの 3 行目右端の時計を押すと Snooze。毎朝、戻り時刻（設定、既定 09:00）にすべての Snooze を解除する。
- Snooze 中は PRs タブからも Activity からも消え、バッジに数えず、通知も鳴らさない。
- 戻るのは戻り時刻と Unsnooze の 2 つだけ。Snooze 中に新しい Needs action が来ても戻さない（その間に来たものも「確認しない」の対象。戻ったカードに青い点とオレンジが付いているので失うものはなく、遅れるだけ）。「来たら知りたい」なら Snooze しない。
- 解除された PR は元の位置に戻る。
- Snooze 中に通知対象の出来事があった PR を、解除時にスコープごとに 1 件の通知にまとめる。押すとポップオーバーを開く。通知対象の出来事がなければ通知しない。手動の Unsnooze（通知のボタンと CLI を含む）では通知せず、まとめ通知の対象の記録を消去する。Snooze より前に起きて渡せなかった通知の記録も同じく消去する。
- チップ Show snoozed をオンにすると、Snooze 中のカードが薄く表示される。見出しに「Snoozed until Mon 09:00」と Unsnooze だけは本来の濃さで表示する。

## カードが出る・消える条件と監視期間

自分の開いている PR はずっと出る。カードが消えるのは、未読がなく未完了の Needs action もない PR のうち、閉じている PR、他の人の Draft、更新がないまま Days without updates before a PR is dropped（既定 14 日）を過ぎた他の人の開いている PR。

- 更新がなくて消えた他の人の PR に新しい出来事が付けば、また出る。
- Merged／Closed：行に Merged／Closed が付き（青い点）、確認すれば消える。左の縦線とラベルが Merged／Closed になり、状況アイコンは表示しない。Comment／Mentioned は Done を押すまで残り、バッジにも数える。
- 他の人の Draft：自分に用（未読・Needs action）がなければ表示しない。Ready for review になれば開いている PR として戻る。自分の Draft は表示する。
- 閉じた PR に新しい出来事が付けば未読が生じ、また出る。
- 読めなくなった PR（id で取得して見つからないと返された PR）は、未読や未完了の行があってもカードを表示せず、バッジにも数えず、青い点を付けず、通知もしない。状態は保存し、再び読めるようになると元に戻る。戻ったときに未読の行があれば、Snooze の解除と同じ規則で青い点を付ける。検索結果に出なくなっただけではカードを変更しない。

カードの位置は追加時に固定し、Snooze の解除や再表示でも変更しない。

**監視**。カードが出ている間は、クローズ後の日数に関係なく監視する。監視日数（設定、既定 3 日）は「カードが消えた時点から」数える。通知 API の Comment／Mentioned は日数に関係なく通知される。日数で外れるのは Reaction の検知。

## macOS 通知

通知するのは、Review requested、Mentioned、自分の PR への Comment、自分がコメントしたスレッドへの Reply、スレッドで自分がメンションされたあとの Reply、自分のコメントへの Reaction（1 回の取得で検知した同じコメントの分は 1 件にまとめる）、自分の PR の状態変化（Checks failed、Conflicts、Changes requested、Removed from merge queue、Mergeable）。他の人の PR の状態、Added to merge queue は通知しない。Bot の Comment は Bot comments の設定だけで決まり（Notify／List only／Hide、既定 List only）、種類ごとの通知のオン・オフは適用しない。スコープの通知がオフならすべて通知しない。

- オン・オフはスコープ単位。
- 個別の通知の文面は、タイトルが「スコープ名 · 行の種類」（`example-org · Mentioned`）、サブタイトルが `owner/repo #番号` と PR のタイトル、本文が行の本文である。Reaction の本文は種類ごとの件数とコメント（`👍3 🎉1 “...”`）とする。
- 通知はスコープごとにまとめる。1 回の配信で、スコープの個別の通知になるはずのものが 2 件以上なら 1 件のまとめ通知にし、1 件なら個別の通知にする。同じコメントの Reaction をまとめた通知は 1 件と数える。通常の取得、アプリの停止のあと、再接続、不在のあとのすべてに適用し、スコープをまたいでまとめない。Snooze の解除は、件数に関係なく `Back from Snooze` の 1 件とする。
- まとめ通知の文面は、Snooze の解除以外が `example-org · 5 new events` と `In 3 PRs`、Snooze の解除が `example-org · Back from Snooze` と `3 PRs had new events` である。N は行の数で、件数が 1 のときは `1 new event`、`In 1 PR`、`1 PR had new events` と単数形にする。
- 不在 10 分以上のあとは、不在の間の通知を 1 回の配信として扱う。まとめ通知を押すとポップオーバーを開く。
- 個別の通知を押すと、その場所を Web で直接開く（ポップオーバーを経由しない。青い点の状態は変更しない）。ボタン Done／Snooze を付け、カードに行かずに処理できる。
- Web を開く操作は「出来事を押す」の 1 種類（カードの行、Activity、macOS の通知、すべて同じ）。「押すとカードを選ぶ」操作は設けない。

## キーボード

↑↓ Move、⏎ Open、D Done／Not done（切り替え）、S Snooze。ポップオーバー下部にヒント 1 行。既読のキーはない（自動で消える）。両タブで同じ。

## 設定項目

タブは General／Scopes／Notifications／Watching。

| タブ | 項目 | 既定 |
| --- | --- | --- |
| General | Launch at login | on |
| General | PR status interval | 1 min |
| General | Reactions interval | 3 min |
| General | GraphQL cost cap (last hour)。80% を超えると警告し、達すると取得を止める（「レート制限」） | 1500 points |
| General | API usage（REST／GraphQL の残り、定期取得 1 回のコスト） | 表示のみ |
| Scopes | Notifications token（classic PAT、notifications と read:org。必須）、SSO 承認が必要なときの警告 | — |
| Scopes | スコープごとの fine-grained PAT（Public も専用のトークンを持つ）、テスト取得の結果、Enabled、通知のオン・オフ | Enabled on、通知 on |
| Notifications | 種類ごとのオン・オフ | on |
| Notifications | Snooze の戻り時刻 | 09:00 |
| Notifications | Bot comments：Notify／List only／Hide（Hide は画面に表示しないだけで、内部には記録する） | List only |
| Watching | Include requests to my teams | on |
| Watching | Days to keep watching after close | 3 |
| Watching | Days without updates before a PR is dropped | 14 |

値の範囲：PR status interval と Reactions interval は 1 分以上、GraphQL cost cap は 100 以上、Days to keep watching after close は 0 以上、Days without updates before a PR is dropped は 1 以上、Return time は `HH:MM`。

**スコープ**。PR のリポジトリの owner が登録済みなら、PR はそのスコープに属する。未登録の owner の公開リポジトリの PR は Public に属する。スコープの表示名は owner のログイン名で、アイコンの形は owner の種類（org または user）で決まる。Public は最初から存在し、削除できない。スコープを disabled にすると、アイコンを表示せず、取得も通知もしない。スコープを削除しても状態は保存し、再登録すると元に戻る。スコープを削除すると Keychain のトークンも削除するので、再登録ではスコープを追加してからトークンを登録する。削除した owner の公開リポジトリの PR は Public に移り、Done と Snooze を引き継ぐ。

## 実装方針

**構成**。デーモン、CLI、アプリの 3 つに分割する。

- デーモン（Rust）：GitHub の取得、状態（表示済み、Done、Snooze、カードの追加時刻、設定、スコープ）の保持と保存、トークン（Keychain の読み書きはデーモンだけ）。Unix ソケットで NDJSON を話し、状態の変化を接続中のクライアントに push する。
- CLI（Rust）：ソケット経由でデーモンを叩くだけのクライアント。
- アプリ（Swift）：UI（メニューバー、ポップオーバー、設定画面）と macOS 通知。CLI と同じソケットでデーモンと話す。デーモンの起動・停止・更新時の入れ替えはアプリが行う（launchd は使用しない）。

**UI**。SwiftUI。メニューバーのアイコンとポップオーバーの枠はまず MenuBarExtra で試し、バッジ付きアイコンとキーボード操作が足りなければ AppKit（NSStatusItem + NSPopover）。常時表示は NSPanel。ログイン時起動は SMAppService。

**トークン**。通知用 classic PAT 1 つ（notifications と read:org のスコープ。組織は SSO 承認が必要）、owner のスコープごとの fine-grained PAT 1 つ、Public 用の fine-grained PAT 1 つ（Repository access は Public repositories で、権限を付けない）。classic PAT は、通知の取得と、Public のチームの所属とチーム宛てのレビュー依頼の読み直しにだけ使用する。すべて読み取りだけ。

- 通知用のトークンは必須である。登録されていない間はどのスコープも取得せず、ポップオーバーは「Add a token in Settings」を表示する。
- スコープと Public のトークンの持ち主は、通知用のトークンの持ち主と同じでなければならない。取得のたびに持ち主を確かめ、異なればそのスコープの取得を止めて警告する。トークンを差し替えると、次の定期取得で自動で再開する。
- トークンの期限の 7 日前から警告を付ける。スコープと Public のトークンはそのスコープに、通知用のトークンはすべてのスコープに付ける。期限のないトークンは警告しない。期限を過ぎたスコープと Public のトークンは、無効なトークン（401）として扱う。
- 通知用のトークンが 401 を返すか期限を過ぎると、すべてのスコープの取得を止めてエラーを表示する。
- 応答に X-GitHub-SSO が付いたら、SSO の承認が必要という警告を付ける。ヘッダーは organization の名前ではなく id を返すので、警告は organization を名指ししない。応答に承認の URL があればそのリンクを、なければ GitHub のトークンの設定ページへのリンクを示す。設定画面は、SSO の承認の状態を常には表示せず、この警告があるときだけ表示する。

**API の使い分け**

| 必要なもの | 取り方 |
| --- | --- |
| どの PR が更新されたか | REST Notifications API（all=true。If-Modified-Since と X-Poll-Interval に従う）。通知は再取得の合図としてだけ使用し、reason で行の種類を決めない |
| Review requested、Mentioned、Comment、Merged／Closed、Added to／Removed from merge queue | 更新された PR の GraphQL timelineItems(since:)。nodes(ids:) でまとめて取る。行の種類は下の判定の表に従う |
| Reply | Reply の対象のスレッドの id を記録し、id でスレッドのコメントを取得する |
| 状況アイコン、状態ラベル | GraphQL：reviewDecision、statusCheckRollup、mergeable、mergeStateStatus、isDraft、compare.behindBy。nodes(ids:) でまとめて（100 件まで） |
| 失敗したチェックの名前 | REST の GitHub Actions（head_sha で絞った workflow run と、その job）の job 名、次に Commit status の名前。statusCheckRollup に含まれない run（Copilot のレビューなど、event が dynamic の run）は除く |
| 自分のコメントへの Reaction | 監視中の PR ごとに、自分のコメント、レビュー、レビューコメント、PR の本文の id を集め、GraphQL の nodes(ids:) で reactionGroups を定期取得し、件数の増加を検知する |
| 対象 PR の発見 | GraphQL search をスコープごとに 4 つ：`is:pr is:open involves:@me updated:>=D`、`is:pr is:open reviewed-by:@me updated:>=D`、`is:pr is:open author:@me`、`is:pr is:open review-requested:@me`（Include requests to my teams がオフなら `is:pr is:open user-review-requested:@me`）（D は Days without updates before a PR is dropped の日数前の日付）。owner のスコープは kind に合わせて `org:` または `user:` を加え、Public は `is:public` を加えて登録済みの owner の PR を除く |
| チームの所属 | owner のスコープはそのスコープの fine-grained PAT（Members: Read）、Public は通知用の classic PAT（read:org）で取得する |
| Public のチーム宛てのレビュー依頼 | Public の fine-grained PAT では requestedReviewer が null になるので、その PR だけ通知用の classic PAT で依頼を読み直し、チームの所属と照らし合わせる |

**レート制限**。GraphQL のコストを rateLimit で毎回確認する。直前 1 時間のコストの合計が GraphQL cost cap の 80% を超えると警告する。取得の間隔は設定の値のまま変更しない。合計が cost cap に達したとき、または GitHub の残量が尽きたときは、通知を含むすべての取得を止め、再開の時刻を付けたエラーを表示する。再開後は通知 API の since で停止中の通知を取得するので、失うのは停止中に起きて元に戻った状態の変化と、出来事の検知時刻だけである。停止中は `refresh` も取得しない。二次レート制限も同じ扱いで、指定の時間（retry-after、x-ratelimit-reset、指定がなければ 1 分）だけすべての取得を止め、再開の時刻を表示し、自動で再開する。残量は設定の General に表示。

**取得の成功と失敗**。スコープの取得の成功は、そのスコープの検索と状況の取得がすべてエラーなく終わったことを指す。成功した時刻を Updated … ago に表示し、PR も出来事もなかった場合も更新する。この時刻は出来事を取得する範囲（「監視開始より前の出来事」）の始まりにも使用する。

- 出来事の取得に失敗した PR は、失敗した時点の取得の範囲の始まりを、その PR の取り直しの時刻として記録する。次の取得ではその時刻から取り直し、成功すれば記録を消す。そのため、スコープの成功の時刻が進んでも出来事を失わない。
- 通知 API の since と Last-Modified は常に進める。通知を合図にした取得に失敗した PR も、同じく取り直しの対象にする。取得できるスコープに属さない PR（取得を止めたスコープ、disabled のスコープ、どのスコープにも属さない PR）の通知は従来どおり無視し、ほかの取得を妨げない。
- 出来事の取得に続けて失敗する PR には、その PR を示す警告を付け、取得のたびに取り直す。

- 権限不足で取得できなかった部分は失敗に数えず、取得できる部分の取得を続けて警告する。SSO の未承認も警告にする。
- ネットワークの失敗、5xx、タイムアウトは失敗で、設定の間隔のまま次の取得で再試行する（間隔を延ばさない）。
- 401 は失敗で、トークンを差し替えるまでそのスコープの取得を止める。
- 上限による停止は失敗である。
- 失敗はスコープごとに扱い、ほかのスコープの取得を止めない。例外として、通知用のトークンの 401 と期限切れは、すべてのスコープの取得を止める（「トークン」）。
- `refresh` は再試行の時刻を待たずにすぐに取得する。401 で止めたスコープも 1 回だけ取得し、401 が続けば止めたままにする。

**状態の保存**。行の「表示済み」、Done、Snooze、カードの追加時刻、監視開始時刻、スコープごとの最後に取得に成功した時刻、PR の前回の値、Reaction の基準値、設定、スコープはデーモンが SQLite に保存する（SQLite はデーモンに組み込み、macOS の libsqlite3 は利用しない）。チップの選択とウインドウの位置は画面の状態なので、アプリが UserDefaults に保存する。GitHub 側には何も書き込まない。トークンは DB に保存せず Keychain に保存する。

**DB を読めないとき**。デーモンは起動するが、GitHub の取得をせず、DB に変更を加えない。アイコンに三角を表示し、ポップオーバーに「Couldn't read saved state」と Reset ボタンだけを表示する。Reset を押すと、DB ファイルを別名で退避し（退避したファイルは削除しない）、空の状態で通常の動作を始める。CLI は `shiibar-gh reset` で同じ操作を行い、ほかのコマンドはエラーになる。DB を読めるときの `reset` はエラーにして、何も変更しない。スコープは Keychain のトークンから復元する。

**fine-grained PAT の権限**（owner のスコープごと。All repositories で発行。Public のトークンは Public repositories で発行し、権限を付けない）

| 権限 | 用途 |
| --- | --- |
| Pull requests: Read | PR、レビュー、コメント、reviewDecision |
| Contents: Read | compare（behindBy）、mergeable |
| Commit statuses: Read | statusCheckRollup、Commit status の名前 |
| Actions: Read | 失敗した GitHub Actions の job の名前 |
| Metadata: Read | リポジトリの基本情報 |
| Members: Read（org のみ） | チームの所属（チーム宛てのレビュー依頼とチームへのメンションの判定） |

fine-grained PAT には Checks の権限がなく、statusCheckRollup の個々の CheckRun を取得できないので、失敗したチェックの名前は GitHub Actions の job から求める。マージキュー（mergeQueueEntry、タイムラインのイベント）は、公開リポジトリでは上の表の権限で取得できた。非公開リポジトリで必要な権限は未決で、権限は追加しない。取得できなければ権限不足の警告にする。

**reason を判定に使用しない理由**。reason は「なぜ自分に通知されるか」を表すスレッド単位の値で、起きた出来事を表さない。一度 mention になったスレッドは、その後メンションされなくても mention のままになる。

**PR の識別**。鍵は GraphQL の node id。通知 API は repo と number しか持たないので、初めて検出した PR は repository(owner, name){ pullRequest(number){ id } } で id を引き、repo#number → id の対応を記憶する。search の結果と通知の PR は id で比較して同じ PR と判定する。

**Needs action の判定**

| 行 | 判定 |
| --- | --- |
| Review requested | REVIEW_REQUESTED_EVENT の requestedReviewer が自分、または自分が属するチーム。チーム宛ての扱いは Include requests to my teams に従う（「行の種類と状態」） |
| Mentioned | MENTIONED_EVENT の actor が自分（actor はメンションされた人）。または、コメント、レビューの本文、レビューコメント、PR の本文の bodyHTML に、自分が属するチームへの team-mention のリンクがある |
| Comment | 自分の PR の ISSUE_COMMENT、レビューの本文、インラインコメントで、author が Bot でも自分でもない |
| Reply | 記録したスレッド（自分がコメントしたスレッド、自分がメンションされたスレッド）の自分以外のコメント。メンションされたスレッドは、メンションより後のコメントだけ |
| Merged／Closed | MERGED_EVENT／CLOSED_EVENT（自分の操作かは問わない） |

同じ出来事が Mentioned と Comment の両方に該当するときは Mentioned の行だけを生成する。Bot の投稿は Mentioned と Reply の行にせず、Bot の Comment の行にする。MENTIONED_EVENT は、createdAt が同じ会話のコメント、レビューコメント、レビューの本文と対応させて、同じ出来事と判定する。同じ createdAt のものが複数あれば、bodyHTML に自分への user-mention のリンクを含むものを選び、それでも複数あればタイムラインの順で最初のものを選ぶ。Mentioned の行の投稿者、本文、飛び先は、対応させたコメントまたはレビューから求める。対応するものがなく、PR の本文に自分への user-mention のリンクがあれば、PR の作者と本文を使用する。それもなければ、投稿者と本文を空にし、PR のページを開く。チームへのメンションは、リンクを含むコメントを Mentioned の行にし、投稿者と本文をそのコメントから求める。本文の文字列から `@org/team` を検索する方法は使用しない。チームへのメンションの検知は、取得の契機に関係なく、取得したすべてのタイムラインで行う。

**行の本文と飛び先**。Review requested の本文は、自分宛てが `for you`、チーム宛てが `for <チームの slug> team` である。Merged と Closed の行は出来事を起こした人を表示し、本文を持たない。Removed from merge queue の行は、取り除いた人（チェックの失敗では github-merge-queue、手動では操作した人）を表示し、本文は理由と PR をキューに追加した人である（`Checks failed · added by alice`）。理由は `failed_checks` を `Checks failed`、`manual` を `Removed manually` と表示し、それ以外の値はそのまま表示する。キューに追加した人は、同じ PR の Added to merge queue の出来事のうち、まだ対応させていない最も古いものの actor とする。理由が `merged` の取り除きは、Merged の行で足りるので行にしない。GitHub が出来事の URL を返さない Review requested とマージキューの行は、PR のページを開く。

**選択とキー**。選択は PRs タブでは「カードの見出し」と「行」を上から順に、Activity では行だけを移る。見出しで ⏎ は PR を開く、S はその PR を Snooze、D は何もしない。行で ⏎ はその場所を開く、D は Done の切り替え（Needs action の行のみ）、S はその行の PR を Snooze。

**Activity に表示する行**。PRs タブに今出ているカードの行だけ。絞り込み（Needs action、My PRs、Others' PRs、Show snoozed）は両タブに同じように適用する。Needs action は Snooze していない PR だけを対象とするので、Show snoozed と同時にオンにしても Snooze 中の PR は表示しない。

**初回、失敗、空**

| 状態 | 見せ方 |
| --- | --- |
| トークン未設定（通知用のトークン、またはそのスコープのトークン） | ポップオーバーに「Add a token in Settings」と Settings ボタンだけ。設定は Scopes タブで開く |
| 取得の失敗 | アイコンに三角。ポップオーバーに黄色い帯「Couldn't reach GitHub · retrying in N min」。N は次の再試行の時刻（`fetch_failed` の警告の時刻）から求める。前回の内容は残す |
| トークンが無効（401） | アイコンに三角。帯に警告。トークンを差し替えるまでそのスコープの取得を止める。前回の内容は残す |
| トークンの期限まで 7 日以内 | アイコンに三角。帯に期限 |
| GraphQL cost cap の 80% を超えた | 帯に警告。間隔は変更しない |
| cost cap に達した、または GitHub の残量が尽きた | アイコンに三角。帯に再開の時刻を付けたエラー。再開まで取得しない |
| カードが 0 件 | 「Nothing needs you」。絞り込みで 0 件なら「Nothing matches」 |
| Activity が 0 件 | 「No activity」 |

**通知 API の取り方**。If-Modified-Since と X-Poll-Interval に従う。50 件ずつ、since は前回の最新。既読の同期はしない（GitHub 側の未読は触らない）。

**CLI（AI 連携）**。`shiibar-gh` コマンドで、ポップオーバーと設定でできる操作をすべて持つ。アプリのローカル状態を読み書きするだけで、GitHub には書き込まない。AI エージェントは Bash から呼ぶ（--help と --json で足りる。CLI の存在と主な使い方は CLAUDE.md に数行記述する）。MCP は作成しない。

| コマンド | 動作 |
| --- | --- |
| list [--scope] [--needs-action] [--mine｜--others] [--snoozed] [--json] | PRs タブと同じ列を出力する |
| status \<pr\> | 状態ラベルと Review／Checks／Base |
| activity [--scope] [--needs-action] [--mine｜--others] [--snoozed] [--json] | Activity タブと同じ流れ |
| done \<row\> / undone \<row\> | Done の切り替え |
| snooze \<pr\> / unsnooze \<pr\> | PR 単位の Snooze |
| refresh | 今すぐ取得する。定期取得と同じ内容（検索、状況、出来事、通知、Reaction）を取得し、反映が終わってから戻る |
| open \<pr｜row\> | その場所の URL を出力する（開くのは呼び元） |
| config get \<key\> / config set \<key\> \<value\> | 設定項目の読み書き（設定画面と同じ項目） |
| reset | DB を読めないときの初期化 |
| scope list / scope add \<owner\> / scope remove \<owner\> / scope enable \<scope\> / scope disable \<scope\> / scope notify \<scope\> on\|off | スコープの登録、enabled と disabled の切り替え、通知のオン・オフ。scope remove は Keychain のトークンも削除する |
| token set notifications / token set \<scope\> / token test notifications / token test \<scope\> | トークンの登録とテスト取得。トークンは標準入力から読み取り、引数には渡さない |
| settings status [--json] | 設定画面の値（API の残量、定期取得 1 回のコスト、トークンごとの状態）を出力する |

`<pr>` は owner/repo#number、`<row>` は list／activity が出力する id、`<scope>` は owner のログイン名または `public`。owner とリポジトリ名の比較は大文字と小文字を区別しない（GitHub の API はログイン名とリポジトリ名を大文字と小文字の違いを問わず解決する。`gh api users/BUFFERINGS` と、GraphQL の `repository(owner:"RUST-LANG",name:"RUST")` が rust-lang/rust を返すことで確認）。`public` と `notifications` という owner は、大文字と小文字の違いを含めて `scope add` でエラーにする。

**トークンの登録とテスト**。`token set` はトークンを保存するだけで、テスト取得をしない。未登録の owner への `token set` は `not_found` にする。`token test` は、標準入力にトークンがあればそのトークンを保存せずに検証し、なければ保存済みのトークンを検証する（設定画面の Test again）。テストは権限の有無だけを確かめ、項目ごとに 1 回問い合わせる。権限のエラーなら Failed と足りない権限の名前を、データがなくてもエラーでなければ OK を、確かめる対象がなければ確認できないことを返す。スコープと Public のトークンの項目は設定画面のテスト結果と同じ（PRs, reviews, comments、Checks、Behind base、Team membership、Merge queue）で、Team membership は org のスコープだけを対象とする（Public は classic PAT で確かめる）。classic PAT（`notifications`）の項目は Notifications、Team membership（read:org）、Scopes（notifications と read:org）の 3 つである。通知用のトークンと持ち主が異なることも結果に示す。`public` は Public の fine-grained PAT、`notifications` は classic PAT を対象とする。

## デーモンの仕様

### ワイヤ形式

Unix ソケットの NDJSON。1 接続 1 要求 1 応答。`subscribe` だけは接続を維持する。応答は `{"ok":true,...}` または `{"ok":false,"code":"...","error":"..."}`。`code` は `not_found`、`invalid`、`internal` のいずれかである。クライアントは未知の `event` とフィールドを無視する。時刻は epoch 秒。

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
| `refresh` | scope（省略可） | `warnings` |
| `open` | pr または row | `url` |
| `config_get`／`config_set` | key、value | `value` |
| `scope_list`／`scope_add`／`scope_remove` | owner | `scopes` |
| `scope_enable`／`scope_disable` | scope | — |
| `scope_notify` | scope、on | — |
| `token_set` | target、token | — |
| `token_test` | target、token（省略可） | `results` |
| `subscribe` | client（`app` または `cli`） | 下の event の流れ |
| `reset` | — | — |
| `settings_status` | — | `api_usage`、`tokens` |
| `info` | — | `version`、`started_at` |
| `shutdown` | — | 応答後に終了 |

`subscribe` は最初に `{"event":"snapshot","scopes":[...],"db_unreadable":false}` を送る。DB を読めない間も `subscribe` と `info` は使用でき、`db_unreadable` が真になる。以降は `{"event":"scope_changed","scope":{...}}` と `{"event":"notify","notification":{...}}` を送る。

DB を読めない状態に移行したとき、およびその状態から `reset` で戻ったとき、デーモンは `subscribe` の接続をすべて切断する。クライアントは再接続し、`snapshot` で新しい状態を受け取る。DB を読めない間の `scopes` は `reset` のあとと同じ内容で、バッジは 0、青い点はなしとする。

`popover_opened` で記録した開いている状態は、`client` が `app` の接続が切れたときとデーモンの起動時に解除する。アプリの異常終了で `popover_closed` を受信できなくても、メニューバーの青い点を付けられるようにするためである。この解除は `popover_closed` として扱わず、`seen_pending` の行は次の `popover_closed` まで保持する。

スコープを削除したときも、デーモンは `subscribe` の接続をすべて切断する。クライアントは再接続し、`snapshot` で最新のスコープを受け取る。アプリは再接続時に、開いているスコープの `popover_opened` を再送する。

スコープの `warnings` と `refresh` の応答の `warnings` の要素は `{"kind":"...","token":"scope"|"notifications","message":"...","until":<epoch 秒または null>}` である。`kind` は `no_token`、`token_invalid`、`token_expiring`、`fetch_failed`、`cost_near_cap`、`rate_limited`、`sso_required`、`permission_missing`、`token_owner_mismatch`、`events_fetch_failed`（出来事の取得に続けて失敗している PR。`message` に PR を示す）のいずれかで、`until` は `fetch_failed` では次の再試行の時刻、`rate_limited` では再開の時刻、`token_expiring` ではトークンの期限である。

`settings_status` の `api_usage` は `{"rest_remaining","rest_limit","graphql_remaining","graphql_limit","cost_per_poll","notifications_poll_interval"}` である。`cost_per_poll` は PR status interval ごとの定期取得 1 回で使用した GraphQL のコストの全スコープの合計（Reaction の取得を含めない）、`notifications_poll_interval` は GitHub が最後に指定した X-Poll-Interval の秒数である。`tokens` は登録の対象（`notifications`、`public`、owner）ごとの `{"target","registered","owner","expires_at","scopes","last_test","sso_urls"}` の配列である。`scopes` は classic PAT の付与済みのスコープ（fine-grained PAT は `null`）、`last_test` は保存済みのトークンの最後のテストの `{"at","results"}`（なければ `null`）、`sso_urls` は SSO の承認の URL の配列（なければ空）である。値がまだない項目は `null` とする。

トークンは `token_set` と `token_test` の中にだけ現れる。デーモンはこれらの要求をログに出力しない。

`refresh` は、取得と反映が終わってから応答する。取得の失敗も `ok` で応答し、失敗は `warnings` で示す。取得中に受信した `refresh` は、実行中の取得の完了を待って応答する。上限による停止中は取得せず、すぐに上限による停止の警告と再開の時刻を返す。

### CLI の終了コード

0 成功、1 接続エラー、内部エラー、不正な値、使用法の誤り（デーモン不在を含む）、2 該当なし（`not_found`）。不正な設定値は保存しない。

### 行の状態遷移

行の鍵は GitHub の出来事の node id。node id を持たない出来事は、状態変化なら PR の id、種類、検知時刻から、Reaction ならコメントの id、種類、検知時刻から合成する。同じ出来事から行を二重に生成しない。

| 契機 | unread | seen_pending | done |
| --- | --- | --- | --- |
| 行の生成 | 立てる | — | 未完了 |
| `seen`（行が画面に表示された） | — | 立てる | — |
| `popover_closed` | seen_pending の行で下ろす | 下ろす | — |
| `done` | — | — | 完了 |
| `undone` | — | — | 未完了 |

`done` と `undone` の対象は今もやることである Needs action の行だけで、それ以外の行は変化しない。

### カードの状態

- 表示の判定は次の順で行う。読めなくなった PR は表示しない。Snooze 中は Show snoozed がオンのときだけ表示する。それ以外は、未読または未完了の Needs action があれば表示する。残りは「カードが出る・消える条件と監視期間」に従う。
- 並びはカードの追加時刻の降順。追加時刻はカードが初めて表示の条件を満たした時刻で、更新しない。
- Snooze は PR ごとの有無だけを保存し、戻る時刻を PR ごとに保存しない。解除は Mac の現在のタイムゾーンの Return time に行う。「Snoozed until」の表示は次の Return time から求める。Return time を変更すると、Snooze 中のすべての PR に反映する。

### 通知の判定

デーモンが行の生成時に通知の要否を判定し、結果を行に保存する。アプリの再起動で再通知しない。Snooze 中の PR の行は個別に通知せず、解除時のまとめ通知の対象として記録する。解除までに Done にした行は対象から除く。種類またはスコープの通知がオフの行はまとめ通知に含めない。通知を渡す時点でも、スコープの通知、種類ごとの通知、enabled、PR を読めるかを確認し、オフ、disabled、読めなくなった PR のいずれかなら通知せず記録を消去する。Bot の Comment は、種類ごとの通知の代わりに Bot comments が Notify であるかを確認する。後からオンに戻しても、消去した分は通知しない。Mac のスリープ中に Return time を過ぎた場合は、復帰時に解除とまとめ通知を 1 回だけ行う。「不在 10 分以上」はアプリが判定する。

デーモンは通知をアプリへ渡したかを記録する。渡せなかった通知は、アプリの再接続時に「macOS 通知」のまとめ方に従って通知する（スコープごとに 2 件以上なら `N new events` のまとめ通知）。Done にした行はこの N に含めない。Snooze の解除のまとめ通知を渡せなかった場合は、その対象の行もこの N に含め、`Back from Snooze` は通知しない。Snooze より前に渡せなかった通知は、Snooze 中は保留し、Return time の解除ではまとめ通知の対象に含め、手動の Unsnooze では記録を消去する。手動の Unsnooze は利用者自身の操作で、青い点とカードの未読で足りるためである。アプリの停止中に起きた出来事も、起動後の取得で検知した分を同じようにまとめる。渡した通知はアプリを再起動しても再通知しない。

### 定数

| 定数 | 値 |
| --- | --- |
| 状態ディレクトリ | `~/.local/state/shiibar-gh/`（`SHIIBAR_GH_STATE_DIR` で変更） |
| ログレベル | info（`SHIIBAR_GH_LOG` で変更） |
| アプリの再接続 | 1 秒から倍々、上限 30 秒 |
| 状態ディレクトリの権限 | ディレクトリ 0700、DB 0600 |

## 未決

- [ ] 非公開リポジトリのマージキューの取得に fine-grained PAT のどの権限が必要か（公開リポジトリでは実装方針の表の権限で取得できた。非公開リポジトリのマージキューは GitHub Enterprise Cloud の organization だけで使用でき、確認できていない）
- [ ] チームへのメンションの判定は、bodyHTML の `team-mention` のリンク（`class="team-mention"` と、チームの databaseId を表す `data-id`）に依存する。この HTML の形は API の仕様ではないので、GitHub が変更すると判定できなくなる
- [ ] 1 つの PR が同時にマージキューに 2 回追加されることがあるか、取り除きが追加の順と異なる順に起きることがあるか（Removed from merge queue の行の、キューに追加した人の対応に影響する。ドキュメントに記載がなく、確認していない）
- [ ] Notifications API（`/notifications`）の応答に X-GitHub-SSO が付くか（ドキュメントは REST の応答一般について記載している。所有者は SSO の organization に属していないので確認できない）
- [ ] SSO の承認が必要という警告の動作全体（SSO を有効にした organization で確認できていない）
- [ ] 通知の書き込みと配信の記録の間にデーモンが強制終了すると、次の再接続のまとめ通知で 1 件多く数える場合がある（M1 から引き継いだ既知の動作で、M2 では変更しない）
