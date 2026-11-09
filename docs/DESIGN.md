# shiibar-gh 設計書

shiibar-gh は、自分が関わっている GitHub の PR について「自分のレビューを待っている PR」と「起きたこと」を macOS のメニューバーで知らせる個人用アプリ。画面デザインは docs/design のモックを正とする。

この版（0.3、M5）は 0.2 の Todo と Done を廃止し、自分のレビューを待っている PR を PR の状態としてカードとメニューバーの数字に表示する。行は操作で既読にし、ポップオーバーには検索、Group by、並びを加える。0.2 のデータは引き継ぎ、0.1 のデータ（DB と Keychain の項目）は引き継がない（「状態の保存」）。

## 概要とスコープ

このアプリの責務は 3 つ。気づく（自分に関係する出来事が起きた）、自分のレビューを待っている PR を見分ける、その場所へ飛ぶ。「何をどう修正するか」は Web の仕事で、アプリは詳細を持たない。

**対象**

- 自分が関わっている PR（作者、レビュアー、メンションされた、コメントした、assign された）。Issue は扱わない。
- **アカウント**（GitHub のログイン）ごとに扱う。アカウントごとにメニューバーのアイコン 1 つ、classic PAT 1 つ、ポップオーバー 1 つを持つ。
- アカウントの下に **owner**（組織または個人）と **Public** を登録する。PR は owner ごとに区別して表示し、1 つの一覧に混在させない。Public はアカウントごとに 1 つで、最初は存在せず、使用するときに追加する。
- 同じ owner を複数のアカウントに登録できる。ログインが違えば「関わっている PR」は別物であり、両方のアイコンに表示し、通知も別に行う。
- 画面の表記は英語だけ。GitHub にある用語は GitHub の表記のまま使用する。

**対象外**

- GitHub への書き込み（既読の同期も含めて一切しない）。
- GitHub Enterprise Server。
- 他の人の PR の会話のコメント。ただし、自分へのメンションと、Reply の対象のスレッドへの返信は対象にする（「行の種類と状態」）。
- 0.1 からのデータの移行。

## 画面構成

**メニューバー**。アカウントごとにアイコン 1 つ（幅固定。1 アカウントでも 1 つ）。絵柄は shiibar-gh のもので全アカウント同じで、アカウントの色（「アカウントの色」）で塗る。右上の青い点＝新しい出来事あり、右下の数字＝レビュー待ちの PR の数（「レビュー待ちの定義」。100 以上は `99+`。アクセシビリティの文言は `N review requests`（1 なら `1 review request`）、0 なら `No review requests`）、三角＝注意（トークンの期限と無効、取得の失敗、上限による取得の停止、Keychain を読めない）。画像は絵柄を中央に配置し、点と数字を角に少しはみ出させる（大きさは実機で決める）。アカウントが 1 つもないときは、shiibar-gh のアイコンを 1 つだけ表示する。押すと「No accounts yet」「Add an account in Settings」と Settings ボタン、⌄ のメニューを表示する。

**ポップオーバー**。幅 460px（文字の大きさが 12 のとき。「文字の大きさ」）。押したアカウントだけを表示する。上から：

1. 見出し：アカウント名（前にアカウントの色の丸）、その下の行に `Updated 1 min ago · API 25%`、Open in window、Refresh、Settings、⌄ のメニュー（About shiibar-gh、Settings…、Quit shiibar-gh）。Updated は、そのアカウントの取得が最後に成功して終わった時刻である（「取得の成功と失敗」。成功したことがなければ `Not updated yet`）。API は GraphQL と REST の使用率の高い方を整数の百分率で表示する（「レート制限」）。警告があるときだけ黄色い帯（「警告の表示」）。ポップオーバーを開いている間と、常時表示ウインドウにフォーカスがある間は ⌘Q でも終了する。終了するとデーモンも止まる。
2. タブ：**PRs**（セクションに PR のカード）と **Activity**（全 PR の行を新しい順に 1 本で）。
3. 絞り込みの 1 行目：チップ **All｜Authored by me｜Assigned to me｜Review requested**（GitHub の Pull requests ダッシュボードの既定の絞り込みと同じ名前。shiibar-gh の All は GitHub の Involves me に相当する）。左寄せで、幅は文字の分だけとし、ポップオーバーやウインドウの幅が広がっても伸びない。常に 1 つがオンである。件数は表示しない。全セクションに適用する。Activity タブでは、この行の代わりに owner のボタンの行（先頭が `All owners`、続いて owner 名）を表示し、オンにした owner の行だけを表示する（複数を同時にオンにできる。owner をすべてオフにした状態が `All owners` で、すべて表示する。`All owners` を押すと owner のボタンをすべてオフにする。記憶した選択が空のときは `All owners` をオンに表示し、owner を 1 つでもオンにすると `All owners` はオフになる。すべての owner を個別にオンにしても `All owners` はオフのままである。記憶した選択の中の削除済みと disabled の owner は無視する）。
4. 絞り込みの 2 行目：検索欄（プレースホルダー `Search`。⌘F で移動する）、Group by のポップアップボタン、並びのポップアップボタン（どちらも今の値を表示する）。幅に合わせて伸びるのは検索欄だけである。Activity タブでは検索欄だけを表示する（Group by と並びは PRs タブだけ）。
5. カードの列（PRs）または行の列（Activity）。
6. キーのヒント 1 行（「キーボード」）。

コントロールは macOS の標準のものを使用し、オンの色は OS のアクセントカラーで、アプリ側で固定しない。絞り込みの選択、Group by、並び、折りたたみ、Activity の owner の選択は、アカウントごとに記憶する。検索の文字は記憶しない（「キーボード」）。絞り込みと検索の意味は「絞り込みの意味」に記述する。

**PRs タブのセクション**。Group by の値でセクションを区別する。

| Group by | セクション |
| --- | --- |
| `Owner` | owner ごとに 1 つ。並びは登録の順で、Public は常に最後 |
| `Repository` | owner/repo ごとに 1 つ。名前の順 |
| `Status` | `Open`、`Draft`、`Merged`、`Closed` の順 |
| `Involvement` | `Review requested`、`Authored by me`、`Assigned to me`、`Others` の順。複数に該当する PR は、この順で先に該当した 1 つに属する。`Others` はどれにも該当しない PR |
| `None` | セクションを区別しない（Snoozed を除いて見出しを表示しない） |

どの Group by でも（`Owner` を含む）、カードのないセクションは表示しない。カードの有無は、絞り込みと検索を適用したあとのカードで判定する。どの Group by でも、Snooze 中の PR は最後の「Snoozed」セクション（見出しは `Snoozed · 2 PRs · until Mon 09:00`。初期状態は折りたたみ）にまとめ、ほかのセクションには表示しない。

`None` では、Snoozed セクションの前のカードを見出しのない 1 本の一覧にする。並びはセクションの中と同じで、開いている PR を先に、Merged と Closed を後ろに並べ、その次に `+ N more PRs`、最後に Snoozed セクションを配置する。選択は、カードの見出し、行、`+ N more PRs`、Snoozed セクションの見出しの順に移る。見出しのない 1 本の一覧には折りたたみがない。

セクションの見出しは、名前、レビュー待ちの PR の数（赤。0 なら表示しない）、PR の数、折りたたみの山形である。どちらの数も絞り込みと検索に依存せず、Snooze 中と Hidden のリポジトリの PR を除いて数える。Snoozed の件数も絞り込みと検索に依存しない。見出しを押すと折りたたむ。折りたたみは、アカウントごとに、Group by の値とセクションの鍵の組ごとに記憶する。

並び（アカウントごとに記憶する）は `Recently updated`（既定。PR の `updatedAt` が新しい順）と `Recently added`（カードの追加が新しい順）の 2 つである。どの Group by でも、セクションの中では開いている PR（Draft を含む）を先に、Merged と Closed を後ろに並べ、それぞれの中で選択した並びに従う。`Recently updated` では、出来事で `updatedAt` が進んだカードが上に移動する。選択中のカードは、移動しても選択を保つ。

セクションの中で、未読の行がなくレビュー待ちでもない PR は「+ 2 more PRs」の 1 行（1 件なら「+ 1 more PR」）にまとめ、押すと展開する（展開の状態は記憶しない）。Snoozed セクションではカードをまとめず（「+ N more PRs」はない）、すべて表示する。検索の文字があるときはまとめない。チップだけで絞っているときはまとめる。

まとめるかどうかは、アプリがポップオーバーを開いた時点と新しい PR が現れた時点で決める。開いている間は、まとめずに表示した PR をまとめない（最後の未読の行を選んでも、そのカードは「+ N more PRs」に移らない）。ポップオーバーを閉じたときに判定をやり直す。常時表示ウインドウは、フォーカスが外れたときに判定をやり直す。

**通常のアプリへの切り替え**。常時表示のウインドウと設定画面のどちらかが存在する間だけ、アプリは通常のアプリとして動作する。Dock と ⌘Tab にアプリが表示され、画面上端にアプリのメニューを表示する。両方が閉じると常駐の状態に戻り、どちらも表示しない。メニューはアプリのメニューと Edit の 2 つである。アプリのメニューは About shiibar-gh、Settings…（⌘,）、Close Window（⌘W。閉じるウインドウがなければ無効）、Quit shiibar-gh（⌘Q）で構成し、Quit は ⌄ のメニューの Quit と同じくデーモンも止める。Edit は Undo、Redo、Cut、Copy、Paste、Select All である。Dock のアイコンを押すか ⌘Tab で切り替えると、開いているウインドウを前面に表示する。shiibar-cc の DESIGN.md の同じ規則にならう（shiibar-cc は設定画面を対象に含めない）。

**カードの見出し（3 行）**

| 行 | 左から |
| --- | --- |
| 1 | PR の状態ラベル（Mergeable 緑／Draft 灰／Merged 紫／Closed 赤。Open は無印）、owner/repo #番号、`Review requested` のマーク（レビュー待ちの間だけ）、右端に状況アイコン 3 つ |
| 2 | 作者のアバター、タイトル |
| 3 | 左に base ← head、右に `opened 3d ago by alice · updated 2h ago`（薄い文字）、右端に Snooze の時計 |

`Review requested` のマークは、薄いオレンジの地に濃いオレンジの文字の小さなラベルで、PR がレビュー待ち（「レビュー待ちの定義」）の間だけ表示する。行の既読とは独立で、行を既読にしても残る。

3 行目の右の部分は、PR の作成時刻（GraphQL の `createdAt`）、作者、更新時刻（`updatedAt`）である。作成時刻がまだないとき（0.2 から移行した直後で、次の取得の前）は `opened …` を省き、`by alice · updated 2h ago` とする。相対時刻の書式は行の meta と同じで、マウスを乗せると正確な日時を表示する。作者を特定できない PR は `by …` を省く。幅が足りなければ、右の部分を省略せずに 4 行目に折り返す。Snooze の時計は、この部分の右に付く。

状態ラベルと同じ色の縦線をカードの左端にも引く（色だけにしない）。「自分の PR」のタグはなく、アバターで分かる。アバターは作者の GitHub のアイコンの画像（GraphQL の `author.avatarUrl`）である。

**状況アイコン 3 つ**。順番固定 Review／Checks／Base。塗りの ✓ 緑、塗りの × 赤、点線の ◌ 灰。文字は付けない。

| 列 | ✓ | ◌ | × | 値の元 |
| --- | --- | --- | --- | --- |
| Review | Approved | Review required | Changes requested | reviewDecision（null なら最新のレビューから求める） |
| Checks | Passed | In progress（None は空） | Failed | statusCheckRollup |
| Base | Up to date | Behind | Conflicts | mergeable / behindBy |

Base は、behindBy を取得できなければ Conflicts または空とする。mergeable が UNKNOWN なら前回の値を保つ。

Mergeable は mergeStateStatus が CLEAN のときだけで、自前で計算しない。詳細（誰が、どのチェックが、何コミット）は載せず、押すと各軸の場所へ飛ぶ。飛び先は、Review と Base が PR のページ、Checks が PR の Checks のページ（`/checks`）である。この行から「誰の番か」は判断しない。自分のレビューを待っているかは `Review requested` のマークで示す。

**レビュー待ちの定義**。レビュー待ちは PR の状態であり、行の性質ではない。レビュー待ちの PR とは、開いている PR のうち、Snooze しておらず、GitHub の今のレビュー依頼（reviewRequests）に自分または自分のチームが含まれ、最新の依頼のあとに自分のレビューがないものを指す。

- 自分宛ての依頼は、reviewRequests に自分がいれば数える。Review requested の行の有無と、Review requested の List のオンとオフは条件にしない。
- チーム宛ての依頼は、その owner の Review requested to my team の List がオンのときだけ数える。自分宛てと同じく、最新の依頼のあとに自分がレビューしていれば数えない。
- 自分のレビューは、取得している PR のレビュー（author が自分のもの）から判定する。レビューの投稿によって GitHub が依頼を取り消すかは確認していないので、この条件で補う。最新の依頼の時刻は Review requested の行（自分宛てまたはチーム宛て）の時刻で判定し、行がなく時刻が分からないときは、自分のレビューが 1 つでもあれば数えない。
- 依頼した利用者が Exclusions の Hidden または List only の間は、その依頼を数えない（0.2 で Todo にならなかった動作を保つ）。依頼した利用者は、その PR の最新の Review requested の行（自分宛ての依頼では自分宛ての行、チーム宛ての依頼ではチーム宛ての行。記録だけの行を含む）の actor で判定する。行がなく依頼した利用者が分からなければ数える。
- 読めなくなった PR と Hidden のリポジトリの PR は数えない。

メニューバーの数字とセクションの赤い数字はこの PR の数である。依頼が取り消されるか、最新の依頼のあとに自分がレビューすると、レビュー待ちではなくなる（再び依頼されると戻る）。状況アイコンの赤はレビュー待ちに関係しない。

**押したときの動作**。カード内に開閉はない。カードの見出しと行は、クリックで選び（行は既読になる。「未読の消え方」）、ダブルクリックで開き（カードの見出しは PR のページ、行はその出来事の場所。⏎ と同じ）、右クリックでその項目を選んでから（行なら既読にしてから）メニューを表示する（「キーボード」）。状況アイコンは押すと Web のその場所へ、時計は押すと Snooze を切り替える。セクションの見出しはクリックで折りたたみ、`+ N more PRs` はクリックで展開する。ホバーでしか表示されない操作は設けない。

**Open in window**。見出しのボタンで、同じ内容を小さなウインドウ（NSPanel）に表示する。アカウントごとに 1 つ、位置と大きさを記憶する。ウインドウの見出しの右側（Refresh、Settings、⌄ の並びの先頭）にピンのボタン（ツールチップ `Keep on top`）を表示する。オンは塗りつぶし（青）、オフは線だけで、オンの間ウインドウを常に手前に表示する。押すとそのウインドウがすぐ切り替わる。値はウインドウの位置と一緒にアカウントごとに記憶し、既定はオンである。ピンのボタンはポップオーバーには表示しない。

**文字の大きさ**。設定の Text size（`text_size`）は本文の文字の大きさ（pt）で、全アカウントのポップオーバーと常時表示ウインドウに共通に適用する。メニューバーのアイコンと設定画面には適用しない。ほかの文字、行の高さ、アバターは、12 に対する比率で連動する。ポップオーバーは幅も比率で連動する。常時表示ウインドウは記憶した大きさを優先し、内容だけを比率で連動させる。ポップオーバーとウインドウでは、⌘= で 1 pt 大きく（⌘+ も同じ）、⌘− で 1 pt 小さく、⌘0 で 12 に戻す。18 での ⌘= と 9 での ⌘− は何もしない（アプリは要求を送らない）。キーで変更した値も設定の値として保存する（範囲と範囲外の入力の文言は「設定項目」）。

**アカウントの色**。選択肢は None、Red、Orange、Yellow、Green、Blue、Purple（Finder のタグと同じ並び）。塗る先はメニューバーのアイコンと、アカウント名の前の丸（ポップオーバーの見出し、設定画面の一覧）だけである。None はアイコンに色を付けず、ほかのメニューバーのアイコンと同じ色（ライトでは黒、ダークでは白）にし、丸は文字と同じ色にする。値は macOS のシステムカラー（systemRed など）を使用し、ライトとダークで自動的に切り替わるものにする（最終の見え方は所有者が実機で確認する）。初期値は、アカウントが 0 件のときに追加したアカウントが None、2 つ目からは Red → Orange → Yellow → Green → Blue → Purple の順で未使用の色を割り当て、すべて使用済みなら Red から再び巡回する（重複を許す）。削除して再び追加したアカウントは新規として扱う。ポップオーバーの背景は全アカウント同じで、owner と Public に色はない。

## 行の種類と状態

カードの下に、その PR の出来事を行で並べる（新しい順）。出来事 1 件が 1 行で、macOS の通知は行から生成する出力である（複数の行を 1 件の通知にまとめることがある）。行は、owner ごとの **出来事の表**（「設定項目」の Notifications タブ。種類ごとに List／Notify の 2 つのチェック）に従って生成する。行はすべて「起きたことの記録」で、未読の青い点、種類のアイコン、ラベルを持つ。

| 種類 | 既定（List／Notify） | 内容 |
| --- | --- | --- |
| Review requested | ✓✓ | 自分にレビューが依頼された |
| Review requested to my team | ✓✓ | 自分が属するチームにレビューが依頼された |
| Mentioned | ✓✓ | 自分がメンションされた |
| My team mentioned | ✓✓ | 自分が属するチームがメンションされた |
| Comment on my PR | ✓✓ | 自分の PR に他の人がコメントした |
| Reply in a thread I commented in | ✓✓ | 自分がコメントしたスレッドに返信があった |
| Reply in a thread I was mentioned in | ✓✓ | 自分または自分のチームがメンションされたスレッドに、そのメンションより後の返信があった |
| Reaction to my comment | ✓✓ | 自分のコメントに Reaction が付いた |
| Approved | ✓✓ | 自分の PR が承認された（承認のレビュー 1 件につき 1 行） |
| Changes requested | ✓✓ | 自分の PR が Changes requested になった |
| Checks failed | ✓✓ | 自分の PR のチェックが失敗した |
| Conflicts | ✓✓ | 自分の PR が base と衝突した |
| Mergeable | ✓✓ | 自分の PR が Mergeable になった |
| Added to merge queue | ✓– | マージキューに追加された |
| Removed from merge queue | ✓✓ | マージキューから取り除かれた |
| Merged / Closed | ✓– | マージまたはクローズされた |

表の見出しは Reviews and mentions（上 4 行）、Comments（次の 4 行）、My pull requests（次の 5 行）、Any pull request（残り）である。

**表の適用**。List は一覧に表示するか、Notify は macOS の通知をするかを決める。List をオフにすると Notify もオフになる。List がオフの種類の Notify をオンにする要求は `invalid` で拒否する。List を再びオンにしても、Notify はオフのままである。Notify は行を生成する時点の表の値で決め、行に保存する。あとから表を変更しても既存の行は変更しない。List は表示の絞り込みなので、変更はすぐ反映する。List がオフの間も行は記録し（未読なし、通知なしで保存する）、未読と通知の対象にしない。List をオンに戻すと、オフの間に記録した行を既読の行として表示し、さかのぼって通知しない。Review requested to my team の List は、チーム宛ての依頼をレビュー待ちに数えるかも決める（「レビュー待ちの定義」）。

**行の見た目**。行は先頭に青い点（未読のときだけ）と種類のアイコンを持ち、既読になると薄く表示する。

**Comment と Reply の対象**。Comment on my PR の行は、自分の PR に他の人が投稿した会話のコメント、レビューの本文、インラインコメントから、1 コメントにつき 1 行を生成する。Approve のレビューの本文も含める。本文付きで変更を求めるレビューは、Changes requested の行と Comment の行の両方を残す。本文付きの承認も同じく、Approved の行と Comment の行の両方を残す。他の人の PR の会話のコメントは行にしない。Reply の 2 種類の行は、自分がコメントしたスレッドへの返信と、スレッドで自分がメンションされたあとの返信から生成し、どの PR でも対象にする。ここでのスレッドは、コードの行に付くレビューのスレッドを指す。Comment と Reply の両方に該当するコメント（自分の PR の、自分がコメントしたスレッドへの返信）は、Reply の行だけを生成する。Mentioned と Reply の両方に該当するコメントは、Mentioned の行だけを生成する。Bot の投稿を特別扱いしない。Bot は利用者と同じく、投稿の内容で行の種類を決める。Bot を一覧や通知から除くには、owner の Exclusions の Users に加える（「Exclusions」）。

どちらの行にも左に青い点（未読）が付く。未読のメンションは本文 3 行、それ以外は 1 行。本文は、改行と連続する空白を 1 つの空白にまとめて表示する（`bodyText` は「The body rendered to text」で、Markdown の記号を含まない。公開スキーマで確認）。

**未読の消え方**。役目は「気づいていない出来事がある」を示すことだけ。行は操作で既読にする。

- 行を選んだ時点（↑↓、クリック、右クリック）で、その行を既読にする。⏎、ダブルクリック、右クリックのメニューの `Open on GitHub` で行を開いたときも既読にする。このとき、アプリは URL を開くとともに `read` を送る。
- ⇧R（右クリックのメニューの `Mark all as read`）は、表示中のタブに今表示している行を既読にする。チップ、検索、owner のボタンを適用したあとの行で、折りたたんだセクションの行は含め、Snoozed セクションの行は含めない。アプリは `read` に行の id を列挙して送る。ワイヤの `read_all` と CLI の `read --all` の範囲はこれと異なる（「ワイヤ形式」）。
- ポップオーバーを閉じただけ、または常時表示ウインドウを閉じたかフォーカスが外れただけでは既読にしない。macOS の通知を押したかは関係しない。未読に戻す操作はない。
- メニューバーの青い点はポップオーバーを開いた時点（常時表示ウインドウにフォーカスが移った時点を含む）で消える。常時表示ウインドウは、フォーカスがある間を開いている、フォーカスがない間を閉じているとして扱う。Snooze 中の行と、List がオフの行、Exclusions で Hidden の行では付けず、Snooze の解除時（手動の Unsnooze を含む）に未読の行があれば付ける。ポップオーバーを開いている間と、常時表示ウインドウにフォーカスがある間は、新着でも解除でも付けず、閉じたときに未読の行が残っていても付けない。
- レビュー待ちは行の既読と独立なので、Review requested の行を既読にしても `Review requested` のマークとメニューバーの数字は残る。Checks／Conflicts／Mergeable は状況アイコンとラベルに残る。

状況アイコンは「今の状態」、行は「起きたことの記録」。Checks が落ちて直ればアイコンは Passed に戻り、Checks failed の行は残る。再び落ちれば新しい行を生成する。

**Review requested の行**。Review requested と Review requested to my team の行は、ほかの行と同じく起きたことの記録で、通常の規則で既読にし、整理する。今もレビューを待っているかは行ではなく PR の状態で判断する（「レビュー待ちの定義」）。再び依頼された場合は新しい行を生成する。

**チーム宛ての依頼とメンション**。チームの所属はアカウントのトークンで取得する（「API の使い分け」）。Review requested to my team の List がオフの owner では、チーム宛ての依頼を行にせず（記録はする）、その owner の検索に `user-review-requested:@me` を使用する。ほかの検索で見つかった PR のチーム宛ての依頼は、記録だけにする。

**残す行の数**。未読の行はすべて残す。既読の行は PR ごとに新しい 3 件を残す。整理はポップオーバーを閉じたとき（常時表示ウインドウを閉じたか、フォーカスが外れたとき）に行う。整理した行は表示しないが内部に記録を残し、再取得で復活させない。Activity も同じ行を表示する。

**Reaction の行**。自分のコメント（会話のコメント、レビューの本文、レビューコメント、PR の本文）の Reaction を種類ごとの件数で検知し、増えた種類ごとに 1 行を生成する。1 回の取得で同じ種類が複数増えた場合は 1 行で件数を表示する（`👍3`）。行の時刻は検知した時刻とする。件数が減っただけのときは行を生成しない。Reaction を削除して再度付けると新しい出来事として扱う。自分が付けた Reaction は件数から除く。監視の外で増えた分は行にせず、監視が戻った時点の件数を基準にする。監視中の PR の自分のコメントは、初めて集めたときの件数を基準にする。ただし、その owner の前回の取得より後に投稿されたコメントは 0 を基準にする。

**Approved の行**。自分の PR への承認のレビュー（state が APPROVED で、author が自分でない）1 件につき 1 行を生成する。PR 全体の判定（reviewDecision）が変更されたかは問わない。承認した人を表示し、本文を持たない。押すとそのレビューを開く。本文付きの承認は Comment on my PR の行も生成する（「Comment と Reply の対象」）。

**状態変化の行**。Changes requested、Checks failed、Conflicts、Mergeable の行は、開いている自分の PR の値が変化したときに生成する。Changes requested は `changes_requested` 以外の値から `changes_requested` に、Checks failed は `failed` 以外の値から `failed` に、Conflicts は `conflicts` 以外の値から `conflicts` に、Mergeable は偽から真に変化した場合である。すでに `failed` の PR で別のチェックが落ちた場合と、すでに `changes_requested` の PR で別のレビュアーが変更を求めた場合は、値が変化しないので行を生成しない。PR を初めて検出した時点では前回の値がないので行を生成しない。行の時刻は検知した時刻とする。本文は、Checks failed が最初に失敗したチェックの名前とほかに失敗したチェックの数（`+N`）、Changes requested が最初のレビュアーのログイン名とほかに変更を求めたレビュアーの数（`+N`）で、Conflicts と Mergeable は本文を持たない。押すと開く場所は、Checks failed が Checks、Conflicts が Base、Changes requested が Review、Mergeable が PR のページである。失敗したチェックは、完了した GitHub Actions の job のうち結果が success、neutral、skipped 以外のものと、状態が FAILURE または ERROR の Commit status である。完了していない job と、PENDING または EXPECTED の Commit status は失敗に含めない。名前を取得できなければ本文を持たない。

**監視開始より前の出来事**。owner の監視開始時刻は、owner を追加した時点、enabled にした時点、DB を空の状態で起動した時点である。この時刻より前の出来事は行にしない。監視開始時刻を設定するときは、その owner の PR の前回の値と Reaction の基準値を破棄する。出来事は、その owner で最後に取得に成功した時刻から 5 分さかのぼった時刻（監視開始時刻より前にはしない）以降のものを取得して行にする。PR を初めて検出した場合も同じで、それより前の出来事は行にしない。アプリの停止中に起きた出来事は、この時刻より後なので行になる。例外として、今も続いているレビュー依頼は、時刻に関係なく未読の行にする（取得の範囲が制限するのは、ほかの出来事の取得だけである）。この行は、依頼が監視開始時刻以降なら通知し、監視開始時刻より前なら通知しない。

## Exclusions

owner ごとに、Repositories と Users の 2 つの一覧を持つ。1 行＝名前と、Hidden｜List only のどちらかの状態である。

- **Hidden**：一覧に表示しない。リポジトリなら、そのリポジトリの PR のカードと行を表示せず、未読、レビュー待ちの数、通知の対象にしない。利用者なら、その利用者が起こした出来事（コメント、レビュー、レビューの依頼、メンション、マージキューの操作、マージとクローズ）の行を表示せず、未読と通知の対象にしない。どちらも内部には記録し、状態を List only にするか一覧から削除すると、Hidden の間に記録した行を既読の行として表示する。Hidden にする前からあった行は元の状態で表示する。
- **List only**：一覧には表示するが、表の値に関係なく通知にしない。
- 追加した直後は List only。「通知だけ除く」はリポジトリ／利用者の単位では持たない。
- 状態変化の行（Checks failed など）と Reaction の行（件数だけを検知し、誰が付けたかを取得しない）は利用者の Exclusions の対象にしない。Approved の行は承認した人が対象である。
- 名前は GitHub に問い合わせずに保存し、大文字と小文字を区別せずに比較する。リポジトリは `owner/repo` の形で指定する。Bot は利用者として扱い、Users に加える。Bot のログイン名は GraphQL の `Bot.login` の表記（`renovate`。`[bot]` の接尾辞なし）で比較する（公開スキーマと実データで確認、2026-11-09）。

## Snooze

Snooze は PR 単位。「この PR は翌朝まで確認しない」をアプリに伝える唯一の入力で、放置（レビュー待ちとして数え続ける）とは違う。目的はメニューバーの数字が「今レビューを待っている PR がある」を意味し続けること。

- カードの 3 行目の時計を押すか、見出しを選んで S を押すか、右クリックのメニューの `Snooze until <時刻>` を選ぶと Snooze。毎朝、戻り時刻（設定、既定 09:00）にすべての Snooze を解除する。
- Snooze 中は Snoozed 以外のセクションからも Activity からも消え、レビュー待ちの数に数えず、通知も鳴らさない。Snoozed セクションにまとめて表示し、見出しに `until Mon 09:00` を表示する。チップと検索は Snoozed セクションのカードにも適用する。絞り込みや検索で Snoozed のカードが 0 件でも、Snooze 中の PR があれば見出しの `until` を表示する。Snoozed セクションのカードは通常のカードと同じ見た目で、3 行目の時計と右クリックのメニューの `Unsnooze` が Unsnooze の操作になる。カードに `Snoozed until` の文や Unsnooze のボタンは配置しない。セクションの中でも行を選んで既読にできる。
- 戻るのは戻り時刻と Unsnooze の 2 つだけ。Snooze 中に新しい出来事やレビューの依頼が来ても戻さない（その間に来たものも「確認しない」の対象。戻ったカードに青い点と `Review requested` のマークが付いているので失うものはなく、遅れるだけ）。「来たら知りたい」なら Snooze しない。
- 解除された PR は、並び（「PRs タブのセクション」）に従う位置に戻る。
- Snooze 中に通知対象の出来事があった PR を、解除時に owner ごとに 1 件の通知にまとめる。押すとポップオーバーを開く。通知対象の出来事がなければ通知しない。手動の Unsnooze（CLI を含む）では通知せず、まとめ通知の対象の記録を消去する。Snooze より前に起きて渡せなかった通知の記録も同じく消去する。

## カードが出る・消える条件と監視期間

自分の開いている PR はずっと出る。カードが消えるのは、未読の行がなくレビュー待ちでもない PR のうち、閉じている PR、他の人の Draft、更新がないまま Days without updates before a PR is dropped（既定 14 日）を過ぎた他の人の開いている PR。

- 更新がなくて消えた他の人の PR に新しい出来事が付けば、また出る。
- Merged／Closed：行に Merged／Closed が付き（青い点）、既読にすれば消える。左の縦線とラベルが Merged／Closed になり、状況アイコンは表示しない。
- 他の人の Draft：未読の行がなければ表示しない。Ready for review になれば開いている PR として戻る。自分の Draft は表示する。
- 閉じた PR に新しい出来事が付けば未読が生じ、また出る。
- 読めなくなった PR（id で取得して見つからないと返された PR）は、未読の行があってもカードを表示せず、レビュー待ちの数に数えず、青い点を付けず、通知もしない。状態は保存し、再び読めるようになると元に戻る。戻ったときに未読の行があれば、Snooze の解除と同じ規則で青い点を付ける。検索結果に出なくなっただけではカードを変更しない。

カードが消える条件を満たしても、ポップオーバーを開いている間（常時表示ウインドウにフォーカスがある間を含む）は消さず、閉じたとき（行の整理と同じ時点）に消す。最後の未読の行を選んだ瞬間にカードが消えないためである。

この判定はデーモンが行う。デーモンは、アカウントごとに「開いている間に表示したカードの PR の集合」を持つ。`popover_opened` のあと、`list` の応答に含めた PR をこの集合に加え、集合にある PR は消える条件を満たしても `list` に含め続ける。`popover_closed`、`client` が `app` の接続の切断、デーモンの起動で集合を空にする。この集合は保存しない。owner の `pr_count` は `list` に含めるカードの数で、同じ集合を使用する。レビュー待ちは PR の状態なので、この集合で保持しない（`review_count` は今の状態から求める）。

カードの追加時刻（`Recently added` の並びの基準）は、Snooze の解除や再表示でも変更しない。

**監視**。カードが出ている間は、クローズ後の日数に関係なく監視する。監視日数（設定、既定 3 日）は「カードが消えた時点から」数える。通知 API の Comment／Mentioned は日数に関係なく通知される。日数で外れるのは Reaction の検知。

## macOS 通知

通知するのは、owner の出来事の表で Notify がオンの種類の行である（既定は「行の種類と状態」の表のとおり。Added to merge queue と Merged / Closed の Notify の既定値はオフ）。Reaction は、1 回の取得で検知した同じコメントの分を 1 件にまとめる。通知の要否は行の生成時に表の値で決める（「表の適用」）。owner の `Notify for <owner>` がオフならその owner のすべての行を通知しない。`Skip draft pull requests` がオンの owner では、Draft の PR の出来事を行にはするが通知しない。Exclusions の Hidden と List only の対象は通知しない。

- オン・オフは owner 単位（`Notify for <owner>`）。種類ごとのオン・オフは表の Notify の列である。
- 個別の通知の文面は、タイトルが「アカウント名 · 行の種類」（`bufferings-work · Mentioned`。種類は表の名前で、Merged / Closed の行は `Merged` と `Closed` に区別する）、サブタイトルが `owner/repo #番号` と PR のタイトル、本文が行の本文である。Reaction の本文は種類ごとの件数とコメント（`👍3 🎉1 “...”`）とする。
- 通知は owner ごとにまとめる。1 回の配信で、owner の個別の通知になるはずのものが 2 件以上なら 1 件のまとめ通知にし、1 件なら個別の通知にする。同じコメントの Reaction をまとめた通知は 1 件と数える。通常の取得、アプリの停止のあと、再接続のすべてに適用し、owner をまたいでまとめない。Snooze の解除は、件数に関係なく `Back from Snooze` の 1 件とする。
- まとめ通知の文面は、Snooze の解除以外がタイトル `bufferings-work · 5 new events` とサブタイトル `example-org · in 3 PRs`、Snooze の解除がタイトル `bufferings-work · Back from Snooze` とサブタイトル `example-org · 3 PRs had new events` である。N は行の数で、件数が 1 のときは `1 new event`、`in 1 PR`、`1 PR had new events` と単数形にする。
- アプリは、デーモンから受け取った通知を保持せずにすぐ表示し、macOS の既定の通知音を鳴らす。まとめ通知を押すとそのアカウントのポップオーバーを開く。
- 個別の通知を押すと、その場所を Web で直接開く（ポップオーバーを経由しない。青い点の状態は変更しない）。通知にボタンは付けない。Snooze は、ポップオーバーと CLI で行う。
- ポップオーバーの中で出来事を Web で開く操作は、行を開く操作（⏎、ダブルクリック、右クリックのメニューの `Open on GitHub`）である。カードの行と Activity で同じである。

## キーボード

↑↓ Move、⏎ Open、S Snooze／Unsnooze、⇧R Mark all read、⌘F Search。行のキーは両タブで同じで、S はカードの見出しだけで使用できる（Activity には見出しがないので S はない）。⇧R は表示中のタブに今表示している行を既読にする（「未読の消え方」）。⌘F は検索欄に移動する。⌘=、⌘−、⌘0 は文字の大きさを変更する（「文字の大きさ」）。

**検索欄**。ポップオーバーを開いたときに検索欄にフォーカスは移らない。⌘F で検索欄に移る。検索欄で Esc を押すと、文字があれば文字を消して一覧に戻り、空なら一覧に戻るだけである（ポップオーバーは閉じない）。検索欄で ↓ を押しても一覧に戻る。検索欄にいる間、⇧R と S は文字として入力する。検索の文字は PRs と Activity で別に持ち、ポップオーバーを閉じたとき（常時表示ウインドウは閉じたとき）に消す。

ポップオーバー下部のヒント 1 行は、選んでいるものに合わせて使用できるキーだけを、押した結果の表現で表示する。⇧R と ⌘F は、どの状態でも表示する。

| 選択 | ヒント |
| --- | --- |
| カードの見出し | `↑↓ Move  ⏎ Open  S Snooze  ⇧R Mark all read  ⌘F Search`（Snoozed セクションでは `S Unsnooze`） |
| 行 | `↑↓ Move  ⏎ Open  ⇧R Mark all read  ⌘F Search` |
| 何も選択していない | `↑↓ Move  ⇧R Mark all read  ⌘F Search` |
| セクションの見出し | `↑↓ Move  ⏎ Collapse  ⇧R Mark all read  ⌘F Search`（折りたたみ中は `⏎ Expand`） |
| `+ N more PRs` | `↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search` |

**マウス**。クリックで選び、ダブルクリックで開き、右クリックでその項目を選んでから（行なら既読にしてから）メニューを表示する（「押したときの動作」）。カードの見出しと行の右クリックのメニューは次の項目である。

| 項目 | 動作 |
| --- | --- |
| `Open on GitHub` | ⏎ と同じ。カードの見出しでは PR、行ではその出来事の場所を開く |
| `Copy link` | PR（行ではその出来事）の URL をコピーする。キーはない |
| `Snooze until <時刻>` | S と同じ（`<時刻>` は次の戻り時刻で、`Snooze until Mon 09:00` の形）。Snoozed セクションでは `Unsnooze`。Activity では表示しない |
| `Mark all as read` | ⇧R と同じ |

## 設定項目

タブは General／Accounts／Watching。設定はその場で反映し、保存ボタンや編集中の状態を持たない。

| タブ | 項目 | 既定 |
| --- | --- | --- |
| General | Launch at login | on |
| General | Appearance：System／Light／Dark（System は Mac の外観の設定に従う） | System |
| General | Text size：本文の文字の大きさ（pt）。数値とステッパー（−／＋）で表示する（「文字の大きさ」） | 12 |
| General | PR status interval | 1 min |
| General | Reactions interval | 3 min |
| General | Return time（Snooze の戻り時刻） | 09:00 |
| Accounts | アカウントと owner の一覧と、選んだものの設定（「設定画面 › Accounts」） | — |
| Watching | Days to keep watching after close | 3 |
| Watching | Days without updates before a PR is dropped | 14 |

General と Watching の各行の 1 行の説明は次のとおりである。Launch at login は "Runs in the menu bar after you log in to your Mac"（登録に失敗したときは "Allow shiibar-gh in System Settings › General › Login Items"）、Appearance は "System follows the appearance setting of your Mac"、PR status interval と Reactions interval は "Shorter means you notice sooner, but uses more API quota"、Return time は "All snoozed PRs come back every day at this time"、Days to keep watching after close は "Reactions are watched this long after a card leaves the list"、Days without updates before a PR is dropped は "Other people's open PRs leave the list after this many quiet days"。数値の欄に整数以外を入力したときは "Enter a whole number" を表示する。Text size の欄は 9〜18 の外の値を受け付けず、範囲外の値を入力したときは "Enter a number from 9 to 18" を表示する。

Text size の 1 行の説明は "Text in the popover and its window" である。

値の範囲：Text size は 9 以上 18 以下の整数、PR status interval と Reactions interval は 1 分以上、Days to keep watching after close は 0 以上、Days without updates before a PR is dropped は 1 以上、Return time は `HH:MM`。

**設定画面 › Accounts**。左にアカウントと owner の 2 段の一覧（アカウント名の前にアカウントの色の丸。owner はアカウントの下に字下げ）、下に `Add account…`。右は選んだものの設定である。

アカウントを選んだとき：

| 見出し | 行 | 右のコントロール |
| --- | --- | --- |
| Account | `Token`。説明はトークンの期限（`Expires 2027-02-01`。期限がなければ説明なし） | 状態の文字（問題と進行中のときだけ。「トークンの状態」）と `Edit…` |
| Account | `Menu bar icon color`。説明は "Tints this account's icon and the dot next to its name." | ポップアップ（色のサンプルと名前） |
| Owners | owner ごとに 1 行。名前と種類（Organization／Personal account／Public repositories） | ›（押すとその owner を選ぶ） |
| Owners | 末尾に右寄せの `Add owner…` | — |
| Remove | `Remove this account`。説明は "Deletes this account and its owners from shiibar-gh: token, PRs, snoozes and settings. Nothing changes on GitHub." | `Remove…`（確認のダイアログのあと削除する） |

owner を選んだとき：Owner／Notifications／Exclusions の 3 つのタブ（セグメント）。開いたときは Owner。

| タブ | 見出し | 行 |
| --- | --- | --- |
| Owner | Owner | `Enabled`（スイッチ。説明 "Off hides this owner's section and stops fetching."） |
| Owner | Remove | `Remove this owner`（説明 "Deletes this owner from shiibar-gh: its PRs, snoozes and settings. Nothing changes on GitHub."。`Remove…`） |
| Notifications | Notifications | `Notify for example-org`（スイッチ。"Off keeps the table below but sends no notifications for this owner."）、`Skip draft pull requests`（スイッチ。"Events on draft PRs stay in the list but never notify."）。既定値はどちらもオン |
| Notifications | Events | 出来事の表（List／Notify のチェックボックス）と、最後の行 `Copy table from another owner`（説明 "Replaces the table above with that owner's."）`Copy…` |
| Exclusions | Repositories | 説明 "Hidden: not in the list. List only: in the list, but no notifications."、枠付きの一覧（名前と Hidden｜List only のセグメント）、下に ＋ − |
| Exclusions | Users | 説明 "Same for a user. Bots are users too."、同じ形の一覧 |

Copy… のシート（題は `Copy table to example-org`）は、`Copy from` のポップアップで相手の owner を選ぶと、その owner の表を読み取り専用で表示し、Copy ボタンでその場で反映する。写すのは表だけで、スイッチと Exclusions は写さない。差分は表示しない。

**owner**。PR のリポジトリの owner がそのアカウントに登録済みなら、PR はその owner に属する。未登録の owner の公開リポジトリの PR は、そのアカウントの Public に属する。owner の表示名は owner のログイン名で、種類（Organization／Personal account）は追加時の問い合わせで決まる。owner を disabled にすると、セクションを表示せず、取得も通知もしない。Public がないときは、未登録の owner の PR を表示せず、取得もしない。owner とアカウントの削除は、その PR、行、Snooze、設定をすべて削除する（再び追加しても戻らない）。アカウントの削除はトークンも Keychain から削除する。owner の追加と削除は Keychain の項目を変更しない。

**Add owner… のシート**。owner のログイン名の欄と `Add`、`Add Public instead`（押すとその場で Public を追加して閉じる。Public がすでにあれば押せない）。Add で `owner lookup`（アカウントのトークンで `GET /users/{owner}` を引く）を実行し、見つかれば種類と数値の `id` を保存して閉じる。見つからなければ `Owner not found`、GitHub に接続できなければ `Couldn't reach GitHub` を欄の下に表示して閉じない。トークンの画面は続かない。

**Add account… と Edit… のシート**。同じ作りで、題は `Add account` と `Token for bufferings-work`。1. Create a token on GitHub（`Create token…` のボタンと、SSO の注記 "If an organization enforces SAML SSO, authorize the token for it after creating it (Configure SSO on the token page)."）。2. Paste the token and test it（貼り付ける欄と `Test`。欄の表示は常に点で、Edit… では保存済みを示す固定 12 個の • を表示する。アプリはトークン本体も文字数も知らない）。`Test` は保存せずに検証し、結果を一覧に表示する（「トークンの登録とテスト」）。結果の領域はシートを開いた時点で確保し（4 項目と owner の数の行）、結果が出るまでは項目名だけを薄く表示する。シートの高さは結果によって変更しない。OK でない項目があるときだけ、Save の行の左に `You can save now and test again later.` を表示する。Save は持ち主を確かめてから保存して閉じる（「トークン」）。Account の項目が ✗ のときは Save できない。Edit… では貼り替えたときだけ Save できる。途中でやめた場合、アカウントは作成しない。Save のあと、デーモンは保存したトークンで `token test` と同じ検証を行って `last_test` を更新し、その間は Token の行に `Checking…` を表示する（進行中を示す項目はワイヤに持たず、アプリは Save の応答から `last_test` が更新された `account_changed` までを進行中として扱い、300 秒を過ぎても更新がなければ進行中の表示をやめる）。問題があれば状態の列に理由を表示する（「トークンの状態」）。

**設定画面の規則**

1. 1 行＝左にラベルと 1 行の説明、右にコントロール 1 つ（状態の文字が付くことはある）。右の列は 240px 固定で右端に揃える。
2. コントロールは 6 種類：スイッチ、セグメント（2〜3 択で 1 行に収まるとき）、ポップアップ（4 択以上、または選択肢が長いとき）、数値とステッパー（Text size）、ボタン（押すものはすべてボタン。シート、ダイアログ、別のウインドウ、別のアプリが続くときは末尾に …）、状態の文字（問題と進行中だけ。正常なときは表示しない）。青い文字のリンクは使用しない。チェックボックスは表の中だけ。Test の結果はシートの中に表示する。
3. 行を押して先へ進むものは右端に ›。
4. 名前を打ち込むだけの一覧（Exclusions の Repositories、Users）は枠付きの一覧に ＋ −。自分の画面を持つもの（アカウント、owner）は一覧の末尾に `Add account…`／`Add owner…`。チップは使用しない。
5. Remove は末尾の独立した見出し。赤くしない。押すと確認を表示し、説明に「何が消えて、何が残り、GitHub 側は変更されない」を記述する。確認の題は `Remove <名前>?`、ボタンは `Remove` と `Cancel` である。
6. すべての枠に見出しを付ける。タブは場所、見出しは枠の内容。
7. owner の設定は 3 タブ、アカウントの設定はタブにしない。トークンの行は 1 行で、右のボタンは Edit… の 1 つ。
8. 押した直後に進行中の表示（状態の列に `Checking…`、ボタンは押せない）にし、結果が出たら置き換える。シートのボタンは押している間、`Test` は `Checking…`、`Save` は `Saving…`、`Add` は `Adding…` の表示になり、押せない。アプリは CLI を起動せず、デーモンに直接要求を送る。

## 実装方針

**構成**。デーモン、CLI、アプリの 3 つに分割する。

- デーモン（Rust）：GitHub の取得、状態（未読、Snooze、カードの追加時刻、設定、アカウント、owner）の保持と保存、トークン（Keychain の読み書きはデーモンだけ）。Unix ソケットで NDJSON を話し、状態の変化を接続中のクライアントに push する。
- CLI（Rust）：ソケット経由でデーモンを叩くだけのクライアント。
- アプリ（Swift）：UI（メニューバー、ポップオーバー、設定画面）と macOS 通知。作者のアバターの画像は、デーモンが渡す URL からアプリが読み込む。CLI と同じソケットでデーモンと話す。デーモンの起動・停止・更新時の入れ替えはアプリが行う（launchd は使用しない）。

**配布と署名**。リリース版は GitHub Actions で Developer ID Application の証明書で署名し（hardened runtime）、Apple の公証を受けて GitHub Releases で公開する。利用者は Homebrew の cask（`bufferings/tap`）でインストールする。デーモンと CLI は `.app` の中に同梱し、cask が CLI のリンクを作成する。開発版は、ローカルで作成した固定の署名の ID で署名して `~/Applications` に配置する。アプリは `Shiibar GH.app`、bundle identifier は `shiibar.gh`、同梱するデーモンと CLI の署名の識別子は `shiibar.gh.daemon` と `shiibar.gh.cli` で、変更しない（Keychain と通知の許可が識別子に結び付くため）。対応する macOS は 14 以上で、Apple Silicon だけを対象とする。Keychain の項目の許可は、保存したプログラムの designated requirement（DR）に結び付く。Developer ID の DR は Team ID と識別子で決まり、版を更新しても満たされるので、更新で許可のダイアログを表示しない。ad hoc の署名の DR は、その版のコードに結び付く（Apple TN3127 で確認。2026-11-05）。開発版とリリース版を切り替えたときは、DR が異なるので 1 回ダイアログを表示する。

**UI**。SwiftUI（足りない部分は AppKit）。メニューバーのアイコンは NSStatusItem、ポップオーバーは NSPopover、常時表示は NSPanel。ログイン時起動は SMAppService。外観は設定の Appearance に従い、System なら macOS のライトとダークの設定に従う。ボードはライトだけなので、ダークの色は実装で決め、所有者が実機で確認する。

**Launch at login の同期**。設定の値（`launch_at_login`）と macOS のログイン項目の登録は、後から変更したほうに合わせる。CLI などで設定を変更すると、デーモンはアプリに設定の変更を知らせ、アプリはログイン項目を登録または解除する。システム設定でログイン項目を変更した場合は、アプリが次に起動したとき、または設定画面を開いたときに、その状態を設定に反映する。

**トークン**。アカウントごとに classic PAT 1 つ。スコープは `repo`、`notifications`、`read:org`。通知、PR の検索と詳細、チェック、チームの所属、Public の取得をすべてこのトークンで行う。owner と Public はトークンを持たない。アプリは GitHub に書き込まないので、`repo` が書き込みを許すことは受け入れる。classic にそろえる理由は、通知 API が classic PAT でしか使用できないためである（fine-grained PAT の権限の一覧に通知のエンドポイントがない。docs.github.com の「Permissions required for fine-grained personal access tokens」で確認、2026-11-08）。

- アカウントの識別子は GitHub のユーザーの数値の id（GraphQL の `viewer { databaseId login }`。REST の `GET /user` の `id` と同じ値）で、表示名は login である。node id は形式の移行中で同じ人の id が変更されうるため（docs.github.com「Migrating GraphQL global node IDs」、2026-11-09 に確認）、識別子には使用しない。`databaseId` は公開スキーマで `Int`、非推奨の印なし（2026-11-09 に確認）。GitHub 側で login を変更すると、次の取得で表示、Keychain の項目の login、CLI の `<account>` も新しい login に追従する。
- 保存の手順。`token set`（トークンは標準入力）は、保存の前に `viewer { databaseId }` で持ち主を確かめる。アカウントと同じ id なら保存する。違えば `Belongs to octocat`（octocat はそのトークンの login）を返して保存しない。GitHub に接続できなければ `Couldn't reach GitHub` を返して保存しない。`account add`（トークンは標準入力）は、`viewer` で id と login を取得してアカウントを作成し、保存する。接続できなければ何もしない。同じ id のアカウントがあれば `bufferings-work is already added` を返す。
- 取得は保存済みのトークンをそのまま使用し、デーモンが持ち主を再確認することはない（classic PAT の持ち主は変更されない）。アカウントの付け替えはなく、Remove してから Add account… する。
- トークンの期限の 7 日前からそのアカウントに警告を付ける。期限のないトークンは警告しない。期限を過ぎたトークンは、無効なトークン（401）として扱う。
- トークンが 401 を返すか期限を過ぎると、そのアカウントのすべての取得を止めて警告する。トークンを差し替えると、次の定期取得で自動で再開する。
- トークンのないアカウント（`token reset` のあと）は取得せず、`no_token` の警告を付ける。トークンを登録すると、次の定期取得で再開する。このアカウントでの `public` 以外の `owner_add` と `owner_lookup` は `invalid`（`Account has no token`）で拒否する。認証なしで GitHub に問い合わせることはない。
- 応答に `X-GitHub-SSO` が付いたら、SSO の承認が必要という警告を付けるかを判定する。ヘッダーは organization の数値の id を返す（`X-GitHub-SSO: partial-results; organizations=21955855,20582480`。docs.github.com/en/rest/authentication/authenticating-to-the-rest-api で確認、2026-11-05）ので、そのアカウントの登録済み owner の数値の id（`owner lookup` で保存した `github_id`）と比較し、一致した owner ごとに `SSO authorization required for example-org` の警告を付ける。一致しない organization は無視し、警告を付けない。1 つの organization への 403 では、ヘッダーは承認の URL だけを返し、organization の id を返さない（同じページで確認、2026-11-10）。この形は、owner ごとの要求（検索）で受けたときはその owner の `sso_required` とし、複数の owner にまたがる要求（状況の取得、通知）で受けたときはその取得の失敗として扱う（警告は付けず、再試行と 5 分の帯の対象にする）。owner を示さない `sso_required` の警告は付けない。帯の `Authorize…` はヘッダーの URL（なければ GitHub のトークンの設定ページ）を開く。ほかの owner の取得は続くので三角は付けない。承認後は次の取得でヘッダーが消え、警告も消える。
- Create token… は `https://github.com/settings/tokens/new?scopes=repo,notifications,read:org&description=shiibar-gh` をブラウザで開く。期限は指定せず、GitHub の既定に従う。

**トークンの状態**。設定画面の Token の行の右には、次のうち最も上のものを 1 つ表示する：`Checking…`（進行中）、`Keychain unavailable`（「Keychain を読めないとき」。Edit… を表示しない）、`No token`（灰、`no_token`。Edit… は空の欄で開く）、`Invalid`（赤、`token_invalid`）、`Expires in N days`（黄、`token_expiring`。1 日未満は切り上げて `Expires in 1 day`）、`Missing scope`（黄、`scope_missing`）、`SSO authorization required`（黄、`sso_required`）。正常なときは何も表示しない。

**Keychain を読めないとき**。デーモンは起動直後の最初の取得で Keychain を読み込み、成功したトークンを保持する。読み込むのは DB にアカウントが 1 件以上あるとき、または `reset` の直後だけで、アカウントのない DB で起動したときは Keychain に触れない。項目がなく DB にアカウントがあるときは、すべてのアカウントを `no_token` にし、`keychain` は `ok` とする。読み込めなければ、前回の内容を表示したまますべてのアカウントの取得を止め、自動では再読み込みしない。2 種類に区別する。OS のエラー（許可の拒否など）は `keychain_unavailable`、項目はあるが内容を読み取れないときは `tokens_unreadable` である。

- アプリは起動直後にダイアログで知らせる。`keychain_unavailable` は題 `Couldn't read tokens from Keychain`、説明 "If macOS asked whether shiibar-gh may use the Keychain, allow it, then retry."、ボタン `Retry`（既定）と `Not now`。Retry と Reset が失敗したときは同じダイアログをもう一度表示する。`tokens_unreadable` は題 `Saved tokens are unreadable`、説明 "Reset deletes the Keychain item. You enter every token again. PRs, snoozes and settings stay."、ボタン `Reset tokens`（既定）と `Not now`。
- Not now で閉じると、すべてのアカウントのアイコンに三角、ポップオーバーと設定画面の Accounts の上端に帯（文面と `Retry…`／`Reset tokens…`）が残る。帯のボタンは同じダイアログを表示する。Retry して失敗したら同じダイアログをもう一度表示する。
- 読めない間はトークンに触れる操作を止める。Token の行は Edit… を表示せず状態 `Keychain unavailable` だけ、`Add account…`、アカウントの `Remove…`、Add owner… のシートの `Add`（GitHub への問い合わせにトークンが必要になる）は押せない。`Add Public instead`、owner の削除、Enabled は使用できる。
- CLI では Retry は `refresh`、Reset は `token reset` である。`token reset` は Keychain の項目を削除し、すべてのアカウントをトークンなし（`no_token`）にする。アカウント、owner、PR、行、設定は残る。
- DB を読めないときは従来どおり帯だけで、ダイアログは表示しない。

**API の使い分け**

| 必要なもの | 取り方 |
| --- | --- |
| どの PR が更新されたか | アカウントごとに REST Notifications API（all=true。If-Modified-Since と X-Poll-Interval に従う）。通知は、すでに知っている PR の再取得の合図としてだけ使用し、知らない PR を取り込まない。reason で行の種類を決めない |
| Review requested、Mentioned、Comment、Merged／Closed、Added to／Removed from merge queue | 更新された PR の GraphQL timelineItems(since:)。nodes(ids:) でまとめて取る。行の種類は下の判定の表に従う |
| Reply | Reply の対象のスレッドの id を記録し、id でスレッドのコメントを取得する |
| 状況アイコン、状態ラベル、assignees、作成時刻 | GraphQL：reviewDecision、statusCheckRollup、mergeable、mergeStateStatus、isDraft、compare.behindBy、assignees、createdAt（`PullRequest.createdAt: DateTime!`。公開スキーマで確認、2026-11-10）。nodes(ids:) でまとめて（100 件まで） |
| 失敗したチェックの名前 | REST の GitHub Actions（head_sha で絞った workflow run と、その job）の job 名、次に Commit status の名前。statusCheckRollup に含まれない run（Copilot のレビューなど、event が dynamic の run）は除く |
| 自分のコメントへの Reaction | 監視中の PR ごとに、自分のコメント、レビュー、レビューコメント、PR の本文の id を集め、GraphQL の nodes(ids:) で reactionGroups を定期取得し、件数の増加を検知する |
| 対象 PR の発見 | 検索だけで行う（通知からは発見しない）。アカウントのトークンで、owner ごとに GraphQL search を 4 つ：`is:pr is:open involves:@me updated:>=D`、`is:pr is:open reviewed-by:@me updated:>=D`、`is:pr is:open author:@me`、`is:pr is:open review-requested:@me`（Review requested to my team の List がオフなら `is:pr is:open user-review-requested:@me`）（D は Days without updates before a PR is dropped の日数前の日付）。owner は種類に合わせて `org:` または `user:` を加え、Public は `is:public` を加え、結果からそのアカウントの登録済みの owner の PR を除く（検索の文字列には除外を加えない。0.1 と同じ） |
| チームの所属 | アカウントごとに REST `GET /user/teams`（`read:org`。0.1 が Public のチームの所属に使用していた API）で、所属するすべてのチームの `id` と `slug` を取得する。owner ごとの問い合わせはしない |
| owner の種類と id | `GET /users/{owner}` の `type`（`Organization` または `User`）と `id` |
| トークンの持ち主と期限 | GraphQL の `viewer { databaseId login }` と、応答ヘッダー `github-authentication-token-expiration` |

**レート制限**。上限は GitHub のもの（アカウントごと。REST API は 1 時間に 5,000 リクエスト、GraphQL API は 1 時間にポイントで数える別の上限。docs.github.com の「Rate limits for the REST API」で確認、2026-11-09）をそのまま使用し、アプリ側の上限は設けない。GraphQL の応答の `rateLimit`（`limit`、`remaining`、`resetAt`）と REST の応答ヘッダー（`x-ratelimit-limit`、`x-ratelimit-remaining`、`x-ratelimit-reset`）を毎回記録する。使用率がどちらかの API で 80% 以上になると警告する（`graphql_near_limit`、`rest_near_limit`）。取得の間隔は設定の値のまま変更しない。残量が尽きたときは、そのアカウントの通知を含むすべての取得を止め、再開の時刻を付けたエラーを表示する。再開後は通知 API の since で停止中の通知を取得するので、失うのは停止中に起きて元に戻った状態の変化と、出来事の検知時刻だけである。停止中は `refresh` も取得しない。二次レート制限も同じ扱いで、指定の時間（retry-after、x-ratelimit-reset、指定がなければ 1 分）だけそのアカウントのすべての取得を止め、再開の時刻を表示し、自動で再開する。

使用量はポップオーバーの見出しの 2 行目に、`Updated … ago` に続けて `· API 25%` の形で表示する。百分率は GraphQL と REST の使用率（使用量＝`limit` − `remaining` を上限で割った値）の高い方を整数で表示する。マウスを乗せると `GraphQL API 1,240 / 5,000 · REST API 100 / 5,000` の形で両方の使用量と上限を表示する（GraphQL はポイント、REST はリクエストで、単位の表記はしない）。80% 以上は警告の色にする。値がまだないときは `API –` とする。一番下のバーの帯はない。設定画面には使用量を表示しない。

**取得の成功と失敗**。owner の取得の成功は、その owner の検索と状況の取得がすべてエラーなく終わったことを指す。成功した時刻は出来事を取得する範囲（「監視開始より前の出来事」）の始まりに使用する。アカウントの取得の成功は、そのアカウントのすべての owner の取得と通知の確認がエラーなく終わったことを指し、1 つでも失敗すればそのアカウントの取得は失敗である。Updated … ago は、そのアカウントの定期取得または `refresh` が最後に成功して終わった時刻である（成功したことがなければ `Not updated yet`）。失敗が続く間は時刻が進まないので、帯が出る前でも古いデータだと分かる。PR も出来事もなかった場合も、成功なら更新する。上限、401、トークンなし、Keychain を読めない状態で取得を止めている間は進まない。

アカウントの定期取得（全 owner の検索と状況の取得、および通知の確認）は 1 回の取得として扱い、その終了時刻から次の取得の時刻を 1 つ決める。成功なら設定の間隔のあととする。失敗なら 5、10、20、40 秒と延ばし、40 秒のあとは 40 秒を繰り返す。どの待ち時間も設定の間隔を超えない。失敗のあとの再試行は、失敗した owner だけでなく、アカウントの取得全体をやり直す。通知の確認は、前回の確認から X-Poll-Interval の秒数がたっていなければその回は省き、省いた回も成功として扱う（「通知 API の取り方」）。Reaction の取得は 0.2 のまま別の時刻（Reactions interval）で行い、アカウントの取得の成功と失敗の判定にも Updated にも関係しない。

`refresh` はいつでもすぐに取得し、通常の 1 回の取得として扱う。成功すれば失敗の回数を 0 に戻し、Updated を進め、次の定期取得をその終了時刻から設定の間隔のあとにする。失敗すれば失敗の回数を 1 つ進め、最初の失敗なら 5 分の起点になる。

- 出来事の取得に失敗した PR は、失敗した時点の取得の範囲の始まりを、その PR の取り直しの時刻として記録する。次の取得ではその時刻から取り直し、成功すれば記録を消す。そのため、owner の成功の時刻が進んでも出来事を失わない。
- 通知 API の since と Last-Modified は常に進める。通知を合図にした取得に失敗した PR も、同じく取り直しの対象にする。知らない PR（repo#number → id の対応がない PR）の通知と、取得できる owner に属さない PR（disabled の owner、どの owner にも属さない PR）の通知は無視し、ほかの取得を妨げない。
- 出来事の取得に続けて失敗する PR には、その PR を示す警告を付け、取得のたびに取り直す。
- スコープ不足で取得できなかった部分は失敗に数えず、取得できる部分の取得を続けて警告する（`scope_missing`）。SSO の未承認も警告にする。
- ネットワークの失敗、5xx、タイムアウト、本文が空の 200 の応答（GraphQL の応答を解釈できないもの）は失敗で、上の待ち時間で再試行する。
- 取得の失敗の帯と三角（`fetch_failed`）は、最初の失敗から 5 分たっても成功していないときに表示し、成功で消す。それまでの失敗は、`Updated … ago` の時刻が進まないことだけで示す。最初の失敗の時刻は保存せず、デーモンの再起動で消える。上限による停止、401、トークンなし、Keychain を読めない状態の間は取得していないので、`fetch_failed` を付けない（それぞれの警告を表示する）。これらの停止を始めた時点で失敗の回数と最初の失敗の時刻は消え、再開後の最初の失敗から再び数える。
- 401 は失敗で、トークンを差し替えるまでそのアカウントの取得を止める。
- 上限による停止は失敗である。停止中は上の待ち時間ではなく、再開の時刻まで取得しない（「レート制限」）。
- 失敗はアカウントごとに扱い、ほかのアカウントの取得を止めない。1 つの owner の失敗は、同じアカウントのほかの owner の取得を止めない。
- `refresh` は再試行の時刻を待たずにすぐに取得する。401 で止めたアカウントも 1 回だけ取得し、401 が続けば止めたままにする。Keychain を読めない状態では、まず Keychain を再読み込みする。

**状態の保存**。行の未読、Snooze、カードの追加時刻、監視開始時刻、owner ごとの最後に取得に成功した時刻、アカウントごとの最後に取得に成功して終わった時刻、PR の前回の値、Reaction の基準値、設定（`text_size` を含む）、アカウント、owner、出来事の表、Exclusions はデーモンが SQLite に保存する（SQLite はデーモンに組み込み、macOS の libsqlite3 は利用しない）。絞り込みの選択、Group by、並び、折りたたみ、Activity の owner の選択、ウインドウの位置と大きさ、`Keep on top` は画面の状態なので、アプリがアカウントごとに UserDefaults に保存する。検索の文字は保存しない。GitHub 側には何も書き込まない。トークンは DB に保存せず Keychain に保存する。すべてのアカウントのトークンは Keychain の 1 つの項目にまとめて保存し、項目にはアカウントの id と login も記録する。開発版は再インストールのたびに Keychain の許可のダイアログを表示するので（ローカルの署名の ID には Team ID がなく、項目の許可がビルドごとの cdhash に結び付くため）、項目を 1 つにしてダイアログを 1 回に抑える。トークンの追加、置き換え、削除は、この項目を読み、変更して保存する。

0.2 の DB（スキーマの版 4）は、起動時に版 5 に移行する。Todo と Done の列（`owner_events.todo`、`pr_rows.seen_pending`、`done`、`todo_auto`、`todo_manual`）を削除するほかは、すべての表とデータをそのまま引き継ぐ。PR の前回の値、Reaction の基準値、通知の配信の記録、整理済みの印、通知 API の since も引き継ぐ。通知だけから取り込んだ 0.2 の PR と行も消さない。移行は 1 つのトランザクションで行い、列を削除し、`prs.created_at`（null 可）を追加し、`user_version` を 5 にする。失敗したらロールバックし、版 4 のまま「DB を読めないとき」の状態にする。Keychain の項目は版 2 のまま変更しない。

開いている間に表示したカードの PR の集合（「カードが出る・消える条件と監視期間」）と、取得の最初の失敗の時刻（「取得の成功と失敗」）は保存しない。

0.1 のデータは引き継がない。0.1 のスキーマの DB は「DB を読めないとき」と同じ扱いにし、Reset で退避する。0.1 の Keychain の項目は読み込まず、0.2 以降は別の名前の項目を使用する。トークンは利用者が再登録する。

**DB を読めないとき**。デーモンは起動するが、GitHub の取得をせず、DB に変更を加えない。アイコンに三角を表示し、ポップオーバーに「Couldn't read saved state」と Reset ボタンだけを表示する。Reset を押すと、DB ファイルを別名で退避し（退避したファイルは削除しない）、空の状態で通常の動作を始める。CLI は `shiibar-gh reset` で同じ操作を行い、ほかのコマンドはエラーになる。DB を読めるときの `reset` はエラーにして、何も変更しない。アカウントは Keychain の項目（id、login、トークン）から復元し、owner は復元しない。

**classic PAT のスコープ**

| スコープ | 用途 |
| --- | --- |
| `repo` | PR、レビュー、コメント、reviewDecision、statusCheckRollup、compare（behindBy）、mergeable、GitHub Actions の job、Commit status、マージキュー。非公開リポジトリを含む |
| `notifications` | Notifications API |
| `read:org` | チームの所属（チーム宛てのレビュー依頼とチームへのメンションの判定）、organization の非公開のチームの参照 |

失敗したチェックの名前は、0.1 と同じく GitHub Actions の job から求める。`repo` で statusCheckRollup の個々の CheckRun を直接取得できる場合は、その方法に置き換えてよい（「未決」）。

**reason を判定に使用しない理由**。reason は「なぜ自分に通知されるか」を表すスレッド単位の値で、起きた出来事を表さない。一度 mention になったスレッドは、その後メンションされなくても mention のままになる。

**PR の識別**。鍵は GraphQL の node id と、それを取得したアカウントの組である。同じ PR を 2 つのアカウントで取得した場合は別の PR として扱い、Snooze と未読を共有しない。PR は検索で見つけたときに取り込む。repo#number → id の対応は、保存した PR（prs 表の owner、repo、number）から求める。通知 API は repo と number しか持たないので、通知の PR はこの対応で id に変換し、すでに知っている PR の再取得の合図にする。対応のない PR（知らない PR）は通知からは取り込まない。0.2 で通知だけから取り込んだ PR も保存した PR なので、対応に含む。

**行の種類の判定**

| 行 | 判定 |
| --- | --- |
| Review requested | REVIEW_REQUESTED_EVENT の requestedReviewer が自分 |
| Review requested to my team | REVIEW_REQUESTED_EVENT の requestedReviewer が自分が属するチーム |
| Mentioned | 自分以外が投稿したコメント、レビューの本文、レビューコメント、PR の本文の bodyHTML に、自分への user-mention のリンクがある |
| My team mentioned | 同じく、自分が属するチームへの team-mention のリンクがある（自分への user-mention もあれば Mentioned だけにする） |
| Comment on my PR | 自分の PR の ISSUE_COMMENT、レビューの本文、インラインコメントで、author が自分でない |
| Approved | 自分の PR の PULL_REQUEST_REVIEW で、state が APPROVED、author が自分でない |
| Reply in a thread I commented in | 自分がコメントしたスレッドの、自分以外のコメント |
| Reply in a thread I was mentioned in | 自分または自分のチームがメンションされたスレッドの、メンションより後の自分以外のコメント |
| Merged／Closed | MERGED_EVENT／CLOSED_EVENT（自分の操作かは問わない） |
| Added to／Removed from merge queue | ADDED_TO_MERGE_QUEUE_EVENT／REMOVED_FROM_MERGE_QUEUE_EVENT |

同じ出来事が Mentioned と Comment の両方に該当するときは Mentioned の行だけを生成する。Mentioned の行の投稿者、本文、飛び先は、リンクを含むコメント、レビュー、または PR の本文から求める。MENTIONED_EVENT は使用しない。GitHub はレビューコメントでのメンションに MENTIONED_EVENT を生成せず、会話のコメントでもコメントより数秒遅れて生成するためである（所有者の確認、2026-11-05）。引用の返信の中のメンションは user-mention のリンクにならないので、Mentioned にしない。本文の文字列から `@login` や `@org/team` を検索する方法は使用しない。メンションの検知は、取得の契機に関係なく、取得したすべてのタイムラインで行う。

**行のラベル**。行の種類のラベルは表の名前である。ただし長い名前は短くする：Comment on my PR は `Comment`、Reply in a thread I commented in と Reply in a thread I was mentioned in は `Reply`、Review requested to my team は `Review requested`（本文の `for <チームの slug> team` で区別する）、Reaction to my comment は `Reaction`。Merged / Closed は `Merged` と `Closed` に区別する。

**行の本文と飛び先**。Review requested の本文は `for you`、Review requested to my team の本文は `for <チームの slug> team` である。Merged と Closed の行と Approved の行は、出来事を起こした人を `by <ログイン名>` の形で本文に表示する。Added to merge queue の行も同じである。Removed from merge queue の行は、取り除いた人（チェックの失敗では github-merge-queue、手動では操作した人）を表示し、本文は理由と PR をキューに追加した人である（`Checks failed · added by alice`）。理由は `failed_checks` を `Checks failed`、`manual` を `Removed manually` と表示し、それ以外の値はそのまま表示する。キューに追加した人は、同じ PR の Added to merge queue の出来事のうち、まだ対応させていない最も古いものの actor とする。理由が `merged` の取り除きは、Merged の行で足りるので行にしない。GitHub が出来事の URL を返さない Review requested とマージキューの行は、PR のページを開く。

**選択とキー**。選択は PRs タブでは「セクションの見出し」「カードの見出し」「行」「+ N more PRs」を上から順に、Activity では行だけを移る。クリックでも選ぶ。行を選ぶと、その行を既読にする。セクションの見出しで ⏎ は折りたたみの切り替え。カードの見出しで ⏎ は PR を開く、S はその PR を Snooze（Snoozed セクションでは Unsnooze）。行で ⏎ はその場所を開く、S は何もしない。「+ N more PRs」で ⏎ は展開。⇧R は選択に関係なく、表示中のタブに今表示している行を既読にする（「未読の消え方」）。⌘F は検索欄に移動する。

**Activity に表示する行**。PRs タブに今出ているカードの行だけである。行は、青い点、種類のアイコン、ラベル、meta（actor と時刻）、本文（未読のメンションは 3 行）、`owner/repo #番号 · タイトル` で構成し、見た目（青い点、種類のアイコン、既読の薄い表示）は PRs タブと同じである。owner 名の列は持たない（リポジトリ名に owner が含まれる）。チップと検索は両タブに同じように適用し、Activity ではさらに owner のボタン（`All owners` と owner 名）で絞る。Snooze 中の PR の行は Activity に表示しない。

**絞り込みの意味**。Authored by me は author が自分の PR、Assigned to me は assignees に自分を含む PR、Review requested は今も自分または自分のチームにレビューが依頼されている PR（チームは、その owner の Review requested to my team の List がオンのときだけ）である。Group by の `Involvement` のセクションも同じ意味で分類する。チップと Involvement の Review requested は GitHub の事実（`review_requested`）で、Exclusions を参照しない。カードの `Review requested` のマークと赤い数は、このアプリのレビュー待ち（「レビュー待ちの定義」。Exclusions とチームの List を反映する）である。

チップ、owner のボタン、検索、Group by、並び、`+ N more PRs` の計算はすべてアプリが行う。アプリは `list` と `activity` を絞り込み（`filter`、`owner`、`owners`）も `search` も付けずに取得する。セクションの数は絞り込みに依存しないので、アプリは絞り込み前のカードを持つ必要があるためである。取得は 1 回ごとに 1 往復で完了し、文字を打つたびにデーモンへ問い合わせない。ワイヤの `filter` と `search` は CLI のためだけに残す。

検索は、検索の文字を空白で単語に分割し、すべての単語が一致した項目だけを表示する。各単語は、次のいずれかに大文字と小文字を区別しない部分一致で一致すればよい：タイトル、`owner/repo#number`（`example-org/api#407` の形）、作者のログイン名、base と head のブランチ名、行の本文、行の actor のログイン名。PRs タブでは一致しない PR（PR の項目にもその行の本文と actor にも一致しない PR）を、Activity では一致しない行（その PR の項目にもその行の本文と actor にも一致しない行）を隠す。セクションの数は変更しない。アプリ（Swift）と CLI の判定（Rust）は同じ規則で、テストは次の例を共有する。

| 検索の文字 | `example-org/api#407` に一致するか | 理由 |
| --- | --- | --- |
| `api 407` | 一致する | `api` と `407` がそれぞれ `example-org/api#407` に含まれる |
| `#407` | 一致する | `example-org/api#407` に含まれる |
| `api #407` | 一致する | 2 つの単語がそれぞれ一致する |
| `API` | 一致する | 大文字と小文字を区別しない |

チップ、owner のボタン、検索で 0 件になったときは `Nothing matches` を表示する。Group by と並びは表示の順と区切りだけを決め、カードを隠さない。

**初回、失敗、空**

| 状態 | 見せ方 |
| --- | --- |
| アカウントがない | メニューバーに shiibar-gh のアイコン 1 つ。押すと「No accounts yet」「Add an account in Settings」と Settings ボタン |
| アカウントに owner がない | ポップオーバーに「No owners yet」「Add an owner in Settings」と Settings ボタンだけ（警告があれば見出しの下の帯は表示する）。設定はそのアカウントを選んだ状態で開く |
| 取得の失敗 | 最初の失敗から 5 分たっても成功していないとき、アイコンに三角。ポップオーバーに黄色い帯「Couldn't reach GitHub · retrying in N min」。N は次の再試行の時刻（`fetch_failed` の警告の時刻）から 0.2 と同じ形式で求める。前回の内容は残す。5 分までは `Updated … ago` の時刻が進まないことだけで示す |
| トークンが無効（401） | アイコンに三角。帯に警告。トークンを差し替えるまでそのアカウントの取得を止める。前回の内容は残す |
| トークンがない（`token reset` のあと） | アイコンに三角。帯に `No token`。登録するまでそのアカウントの取得を止める。前回の内容は残す |
| トークンの期限まで 7 日以内 | アイコンに三角。帯に期限 |
| Keychain を読めない | すべてのアイコンに三角。ダイアログと帯（「Keychain を読めないとき」） |
| API の使用率が 80% 以上 | 帯に警告。見出しの `API 85%` を警告の色にする。間隔は変更しない |
| GitHub の残量が尽きた | アイコンに三角。帯に再開の時刻を付けたエラー。再開まで取得しない |
| カードが 0 件 | 「Nothing needs you」。絞り込みや検索で 0 件なら「Nothing matches」。Snoozed 以外のセクションの代わりに表示し、Snoozed セクションは残す |
| Activity が 0 件 | 「No activity」。絞り込みや検索で 0 件なら「Nothing matches」 |

**警告の表示**。アカウントの `warnings` の種類ごとに、メニューバーの三角と、ポップオーバーの黄色い帯の文面と右のボタンを次のとおりにする。三角は、取得が止まっている、または止まりそうな種類だけに付ける。警告が複数あるときは、表の上の行から順に、すべてを 1 行ずつ帯に並べる。`Settings…` は設定画面をそのアカウントを選んだ状態で開く。

| 種類 | 三角 | 帯の文面 | ボタン |
| --- | --- | --- | --- |
| `keychain_unavailable` | 付ける | `Couldn't read tokens from Keychain` | `Retry…` |
| `tokens_unreadable` | 付ける | `Saved tokens are unreadable` | `Reset tokens…` |
| `no_token` | 付ける | `No token` | `Settings…` |
| `token_invalid` | 付ける | `Token is invalid` | `Settings…` |
| `token_expiring` | 付ける | `Token expires in 5 days` | `Settings…` |
| `fetch_failed` | 付ける | `Couldn't reach GitHub · retrying in 1 min`（最初の失敗から 5 分たっても成功していないときだけ） | — |
| `rate_limited` | 付ける | `Polling paused until 14:05 · GitHub's limit reached` | — |
| `graphql_near_limit` | 付けない | `GraphQL API usage is over 80% of GitHub's limit` | — |
| `rest_near_limit` | 付けない | `REST API usage is over 80% of GitHub's limit` | — |
| `scope_missing` | 付けない | `Token is missing read:org`（足りないスコープを列挙する） | `Settings…` |
| `sso_required` | 付けない | `SSO authorization required for example-org`（登録済みの owner ごと） | `Authorize…` |
| `events_fetch_failed` | 付けない | `Couldn't fetch events for example-org/api #407 · retrying` | — |

**通知 API の取り方**。If-Modified-Since と X-Poll-Interval に従う。`refresh` でも、前回の通知の確認から X-Poll-Interval の秒数がたっていなければ、通知の確認だけを省き、ほかの取得はする。GitHub のドキュメントが X-Poll-Interval に従うよう求めているためである。50 件ずつ、since は前回の最新。既読の同期はしない（GitHub 側の未読は触らない）。

**CLI（AI 連携）**。`shiibar-gh` コマンドで、ポップオーバーと設定でできる操作をすべて持つ。アプリのローカル状態を読み書きするだけで、GitHub には書き込まない。AI エージェントは Bash から呼ぶ（--help と --json で足りる。CLI の存在と主な使い方は CLAUDE.md に数行記述する）。MCP は作成しない。

owner や PR を指す命令は `--account <account>` を必須にする。省略できるのは、`account …`（アカウント名を引数に取る）、`read`（行 id は全体で一意）、`list`／`activity`／`refresh`（`--account` は絞り込み）、`version` だけである。

| コマンド | 動作 |
| --- | --- |
| list [--account \<a\>] [--owner \<o\>] [--authored｜--assigned｜--review-requested] [--search \<text\>] [--snoozed] [--json] | PRs タブと同じ列を出力する。絞り込みと `--search` の判定はデーモンが行い、ポップオーバーと同じ規則（「絞り込みの意味」）で絞る。`--snoozed` は Snoozed セクションの PR だけ。Group by と並びは表示の状態なので持たない。出力の順は Owner の順で、各 owner の中は開いている PR を先にした `Recently updated` の順である。テキスト出力では、レビュー待ちの PR に `[review requested]` を付ける |
| status \<pr\> --account \<a\> | 状態ラベルと Review／Checks／Base |
| activity [--account \<a\>] [--owner \<o\>]… [--authored｜--assigned｜--review-requested] [--search \<text\>] [--json] | Activity タブと同じ流れ。`--owner` は複数指定できる。`--search` は `list` と同じ規則で絞る |
| read \<row\>… / read --all --account \<a\> | 行を既読にする（行を選ぶか開いたときと同じ）／Snooze 中の PR の行を除くアカウントのすべての行を既読にする（ワイヤの `read_all`。⇧R より範囲が広い） |
| snooze \<pr\> --account \<a\> / unsnooze \<pr\> --account \<a\> | PR 単位の Snooze |
| refresh [--account \<a\>] | 今すぐ取得する。定期取得と同じ内容（検索、状況、出来事、通知、Reaction）を取得し、反映が終わってから戻る。Keychain を読めない状態では再読み込みから始める |
| open \<pr｜row\> [--account \<a\>] | その場所の URL を出力する（開くのは呼び元。`<row>` では `--account` を省略できる）。行を既読にしない |
| config get \<key\> / config set \<key\> \<value\> | 設定項目の読み書き（General と Watching の項目。`text_size` を含む） |
| version [--json] | CLI 自身の版と、デーモンの `info` の版を 2 行で出力する（`cli: 0.3.0` と `daemon: 0.3.0`。`--json` は `{"cli":"0.3.0","daemon":"0.3.0"}`）。デーモンに接続できないときは CLI の版を出力し、デーモンの行は `daemon: not running`（`--json` では `"daemon":null`）とする |
| reset | DB を読めないときの初期化 |
| account list [--json] / account add / account remove \<account\> / account color \<account\> \<color\> | アカウントの一覧（テキスト出力のレビュー待ちの PR の数は `review=`）、追加（トークンは標準入力）、削除、色（`none`、`red`、`orange`、`yellow`、`green`、`blue`、`purple`） |
| token set --account \<a\> / token test --account \<a\> / token reset | トークンの差し替え（標準入力）、テスト（標準入力にトークンがあればそれを、なければ保存済みを検証）、Keychain の項目の削除（「Keychain を読めないとき」） |
| owner lookup \<owner\> --account \<a\> | owner の種類と id を `GET /users/{owner}` で求める。見つからなければ `not_found`。owner を登録しない |
| owner list [--account \<a\>] / owner add \<owner｜public\> --account \<a\> / owner remove \<owner\> --account \<a\> / owner enable｜disable \<owner\> --account \<a\> | owner の一覧（テキスト出力のレビュー待ちの PR の数は `review=`）、追加（`public` は Public）、削除、enabled と disabled の切り替え。`owner add` は `owner lookup` を実行して種類と id を保存する |
| owner notify \<owner\> on｜off --account \<a\> / owner skip-drafts \<owner\> on｜off --account \<a\> | Notifications タブの 2 つのスイッチ |
| owner events \<owner\> --account \<a\> / owner events set \<owner\> \<event\> list｜notify on｜off --account \<a\> / owner events copy \<from-owner\> \<to-owner\> --account \<a\> | 出来事の表の表示、変更、コピー。`<event>` は「ワイヤ形式」の種類の値 |
| owner exclusions \<owner\> --account \<a\> / owner exclusions set \<owner\> repo｜user \<name\> hidden｜list-only --account \<a\> / owner exclusions remove \<owner\> repo｜user \<name\> --account \<a\> | Exclusions の表示、追加または状態の変更（なければ作成する）、削除 |

`<pr>` は owner/repo#number、`<row>` は list／activity が出力する id、`<account>` はアカウントの login、`<owner>` は owner のログイン名または `public`。ログイン名とリポジトリ名の比較は大文字と小文字を区別しない（GitHub の API はログイン名とリポジトリ名を大文字と小文字の違いを問わず解決する。`gh api users/BUFFERINGS` と、GraphQL の `repository(owner:"RUST-LANG",name:"RUST")` が rust-lang/rust を返すことで確認）。`public` は Public を指すので、`public` という owner は登録できない。0.1 の `scope …`、`token set notifications`、`list --needs-action`、`undone`、`settings status` と、0.2 の `list --todo`、`activity --todo`、`done`、`todo` は残さない。

**トークンの登録とテスト**。`token set` は持ち主を確かめてから保存する（「トークン」）。`token test` は、標準入力にトークンがあればそのトークンを保存せずに検証し、なければ保存済みのトークンを検証する。項目は次のとおりで、項目ごとに 1 回問い合わせる。

| 項目 | 確かめ方 | 結果 |
| --- | --- | --- |
| Account | `viewer { login databaseId }` | 持ち主の login（`bufferings-work`）。Edit… で id がアカウントと異なれば `✗ Belongs to octocat`。Add account で同じ id のアカウントがすでにあれば `✗ bufferings-work is already added`。接続できなければ `✗ Couldn't reach GitHub`。401 なら `✗ Token is invalid`（ほかの項目は `Can't check`） |
| Scopes | 応答ヘッダー `x-oauth-scopes`（0.1 で使用済み）に `repo`、`notifications`、`read:org` があるか | `✓ OK` または `✗ Missing (read:org)`（足りないものを列挙する） |
| Notifications | `GET /notifications` | `✓ OK` または `✗ Failed (notifications)` |
| Team membership | `GET /user/teams` | `✓ OK`（チームが 0 でも OK）または `✗ Failed (read:org)` |
| 登録済みの owner ごと | その owner の検索 1 つ | `✓ OK`、SSO の承認が必要なら `SSO authorization required` と `Authorize…`、ほかの失敗は `✗ Failed` |

`account add` のシートでは、まだ owner がないので owner の行はない。結果の理由は括弧に記述する。`Can't check` は確かめる対象がないとき、または問い合わせができなかったとき（`Can't check (Couldn't reach GitHub)`、`Can't check (rate limited)`）である。接続はできたが GitHub がエラーを返した項目は `✗ Failed (HTTP 404)` のように状態コードを示す。Account の項目でレート制限に達したときは `✗ Rate limited` にし、残りの項目は `Can't check` にする。GitHub が `databaseId` を返さなかったときは Account を `✗ Failed (no numeric id)` にし、残りは `Can't check` にする（`account add` は `internal`）。標準入力のトークンの検証では、そのトークンの使用量と上限をアカウントに記録しない。`token test` を `--account` なしで実行すると（標準入力のトークンが必須）、Add account のシートの Test と同じく、アカウントを作成せずに検証する。

## デーモンの仕様

### ワイヤ形式

Unix ソケットの NDJSON。1 接続 1 要求 1 応答。`subscribe` だけは接続を維持する。応答は `{"ok":true,...}` または `{"ok":false,"code":"...","error":"..."}`。`code` は `not_found`、`invalid`、`unreachable`（GitHub に接続できない）、`keychain_unavailable`（Keychain を読み込めない間の `account_add`、`account_remove`、`token_set`、保存済みのトークンの `token_test`、`public` 以外の `owner_add` と `owner_lookup`。標準入力のトークンの `token_test` と `token_reset` は受け付ける）、`internal` のいずれかである。クライアントは未知の `event` とフィールドを無視する。時刻は epoch 秒。

| cmd | 引数 | 応答 |
| --- | --- | --- |
| `list` | account、owner、filter（`all`、`authored`、`assigned`、`review_requested`）、search（省略可）、snoozed | `cards` |
| `activity` | account、owners（配列）、filter、search（省略可） | `rows` |
| `status` | account、pr | `card` |
| `read` | row_ids（配列） | — |
| `read_all` | account | — |
| `popover_opened` | account | — |
| `popover_closed` | account | — |
| `snooze`／`unsnooze` | account、pr | — |
| `refresh` | account（省略可） | `warnings` |
| `open` | account（省略可）、pr または row | `url` |
| `config_get`／`config_set` | key、value | `value` |
| `account_list` | — | `accounts` |
| `account_add` | token | `account` |
| `account_remove` | account | — |
| `account_color` | account、color | — |
| `owner_lookup` | account、owner | `owner`（GitHub の表記のログイン名）、`kind`（`org` または `user`）、`id` |
| `owner_add`／`owner_remove` | account、owner（Public は `public`） | `account` |
| `owner_enable`／`owner_disable` | account、owner | — |
| `owner_notify`／`owner_skip_drafts` | account、owner、on | — |
| `owner_events_get` | account、owner | `events` |
| `owner_events_set` | account、owner、event、column（`list`、`notify`）、on | `events` |
| `owner_events_copy` | account、from_owner、to_owner | `events` |
| `owner_exclusions_get` | account、owner | `exclusions` |
| `owner_exclusions_set` | account、owner、kind（`repo` または `user`）、name、state（`hidden` または `list_only`） | `exclusions` |
| `owner_exclusions_remove` | account、owner、kind、name | `exclusions` |
| `token_set` | account、token | — |
| `token_test` | account（省略可。省略時は token が必須で、アカウントを作成せずに検証する）、token（省略可） | `results` |
| `token_reset` | — | — |
| `subscribe` | client（`app` または `cli`） | 下の event の流れ |
| `reset` | — | — |
| `info` | — | `version`、`started_at` |
| `shutdown` | — | 応答後に終了 |

`account` の引数はアカウントの login、`owner` の引数は owner のログイン名または `public` で、応答の中の参照は id で行う。`list` と `activity` の `filter`、`owner`、`owners`、`search` は CLI のための引数で、アプリは付けずに取得する（「絞り込みの意味」）。

アカウントの値は `{"id","login","color","token":{"registered","expires_at","last_test"},"updated_at","review_count","unread","warnings":[...],"rate_limit":{"graphql":{"used","limit","reset_at"},"rest":{...}},"owners":[...]}` である。`owners` は登録の順で、Public は常に最後である（アプリは並べ替えない）。`id` は GitHub のユーザーの数値の id を 10 進の文字列にしたもの（`"3407303"`）、`color` は `none`、`red`、`orange`、`yellow`、`green`、`blue`、`purple` のいずれかで、`account_color` の不正な値は `invalid` になる。`last_test` は保存済みのトークンの最後のテストの `{"at","results"}`（なければ `null`）。`rate_limit` の値がまだなければ `null`。`updated_at` はそのアカウントの取得が最後に成功して終わった時刻（なければ `null`）、`review_count` はそのアカウントのレビュー待ちの PR の数（「レビュー待ちの定義」）である。owner の値は `{"id","name","kind","github_id","enabled","notify","skip_drafts","review_count","pr_count"}` で、`review_count` はその owner のレビュー待ちの PR の数である。`kind` は `org`、`user`、`public` のいずれかである。`id` はデーモンが割り当てる識別子で、ログイン名として解釈しない。`github_id` は `GET /users/{owner}` の数値の `id`（Public は `null`）である。カードと行の値は 0.1（docs/tasks/M1.md の「応答の項目」）の項目を保ち、`scope` を `owner`（owner の id）に、カードの `mine` を `authored_by_me` に置き換え、行の `class` と `done` を削除する。カードはさらに `author_avatar_url`（GraphQL の `author.avatarUrl(size: 32)`。`author` が `null` なら `null`）、`assigned_to_me`、`review_requested`（「絞り込みの意味」の Review requested）、`awaiting_review`（レビュー待ちか。「レビュー待ちの定義」）、`created_at`（GraphQL の `createdAt`。0.2 から移行した直後で、まだ取得していなければ `null`）、`updated_at`（GraphQL の `updatedAt`）を持ち、行は `owner` と `kind` を持つ。`notify` の `notification` も 0.1 の形を保ち、`scope` を `account`（アカウントの id）と `owner`（owner の id）に置き換える。まとめ通知は `title` と `subtitle` を持ち、`body` は `null` である。カードと行も `account` を持つ。

出来事の種類の値（`event`、行の `kind`）は `review_requested`、`team_review_requested`、`mentioned`、`team_mentioned`、`comment`、`reply`、`reply_mentioned`、`reaction`、`approved`、`changes_requested`、`checks_failed`、`conflicts`、`mergeable`、`merge_queue_added`、`merge_queue_removed`、`merged_closed` である。行の `kind` では `merged_closed` の代わりに `merged` と `closed` を使用する。`events` は種類ごとの `{"list","notify"}`、`exclusions` は `{"repos":[{"name","state"}],"users":[...]}` である。

`owner_lookup` は `GET /users/{owner}` で owner の種類と id を求め、owner を登録しない。GitHub のログイン名として不正な owner（英数字とハイフン以外を含む、ハイフンで始まるか終わる、40 文字以上）は問い合わせずに `invalid`、見つからなければ `not_found`、接続できなければ `unreachable`、ほかの失敗は理由を付けた `internal` にする。`owner_add` は同じ問い合わせを行い、成功したときだけ登録する。`account_add` と `token_set` の持ち主の確認が失敗したときの `code` は、持ち主が異なれば `invalid`（`error` は `Belongs to octocat`）、接続できなければ `unreachable` である。

`subscribe` は最初に `{"event":"snapshot","accounts":[...],"keychain":"ok"|"unavailable"|"unreadable","db_unreadable":false}` を送る。DB を読めない間も `subscribe` と `info` は使用でき、`db_unreadable` が真になる。以降は `{"event":"account_changed","account":{...}}`、`{"event":"account_removed","id":"..."}`、`{"event":"keychain_changed","keychain":"..."}`、`{"event":"notify","notification":{...}}`、`{"event":"config_changed","key":"...","value":...}` を送る。`account_changed` は、アカウントの値が変化したとき、またはそのアカウントのカードか行が変化したときに送り、クライアントは `list` と `activity` で一覧を取り直す。`keychain` は最初の読み込みまでは `ok` である。`config_changed` は、`config_set` で設定の値が変化したときに、保存してからすべての購読者に送る。`value` は `config_get` が返す値である。同じ値の `config_set` と、拒否した値では送らない。アプリはこれで `launch_at_login` の変更を知り、ログイン項目を登録または解除する（「Launch at login の同期」）。また `appearance`（`system`、`light`、`dark`）の変更を、ポップオーバー、常時表示ウインドウ、設定画面、メニューバーのアイコンにすぐ反映し、`text_size` の変更を、ポップオーバーと常時表示ウインドウにすぐ反映する。

設定のキーは `launch_at_login`、`appearance`、`text_size`（整数、9〜18。範囲外は `invalid`）、`status_interval_minutes`、`reactions_interval_minutes`、`snooze_return_time`、`keep_watching_days`、`drop_after_days` である（範囲は「設定項目」）。0.1 の `graphql_cost_cap`、`notify_*`、`bot_comments`、`include_team_requests` はない。

DB を読めない状態に移行したとき、およびその状態から `reset` で戻ったとき、デーモンは `subscribe` の接続をすべて切断する。クライアントは再接続し、`snapshot` で新しい状態を受け取る。DB を読めない間の `accounts` は空の配列とする。`reset` のあとの最初の取得で Keychain を読み込み、アカウントを復元する。

`popover_opened` と `popover_closed` は、メニューバーの青い点（「未読の消え方」）、行の整理（「残す行の数」）、カードの消滅の反映（「カードが出る・消える条件と監視期間」）のために開いている状態を伝える。行の既読は変更しない。デーモンは `popover_opened` のあと、`list` の応答に含めた PR を開いている間に表示したカードの集合に加え、`popover_closed` で集合を空にする。`popover_opened` で記録した開いている状態とこの集合は、`client` が `app` の接続が切れたときとデーモンの起動時に解除する。アプリの異常終了で `popover_closed` を受信できなくても、メニューバーの青い点を付けられるようにするためである。アプリは再接続時に、開いているアカウントの `popover_opened` を再送する。

`read` は指定した行の未読を下ろす。存在しない行 id があれば `not_found` を返し、何も変更しない。`read_all` は、Snooze 中の PR の行を除く、そのアカウントのすべての行の未読を下ろす。Hidden や List オフで表示しない行も含む。ポップオーバーの ⇧R は `read_all` を使用せず、表示している行の id を `read` に列挙して送る（「未読の消え方」）。`open` は URL を返すだけで、行を既読にしない。行を開いたときの既読は、アプリが `read` を送って付ける。

アカウントの `warnings` と `refresh` の応答の `warnings` の要素は `{"kind":"...","account":<アカウントの id または null>,"owner":<owner の id または null>,"message":"...","until":<epoch 秒または null>,"url":<文字列または null>}` である。`kind` は「警告の表示」の表の値のいずれかで、`owner` は `sso_required`（常に owner を示す）と `events_fetch_failed` で owner を示し、`until` は `fetch_failed` では次の再試行の時刻、`rate_limited` では再開の時刻、`token_expiring` ではトークンの期限、`url` は `sso_required` の承認の URL である。`keychain_unavailable` と `tokens_unreadable` はすべてのアカウントに付く。

トークンは `account_add`、`token_set`、`token_test` の中にだけ現れる。デーモンはこれらの要求をログに出力しない。

`refresh` は、取得と反映が終わってから応答する。取得の失敗も `ok` で応答し、失敗は `warnings` で示す。取得中に受信した `refresh` は、実行中の取得の完了を待って応答する。上限による停止中は取得せず、すぐに上限による停止の警告と再開の時刻を返す。

### CLI の終了コード

0 成功、1 接続エラー、内部エラー、不正な値、使用法の誤り（デーモン不在を含む）、GitHub に接続できない、Keychain を読めない、2 該当なし（`not_found`）。不正な設定値は保存しない。`version` はデーモンに接続できなくても 0 で終了する。

### 行の状態遷移

行の鍵は GitHub の出来事の node id。node id を持たない出来事は、状態変化なら PR の id、種類、検知時刻から、Reaction ならコメントの id、種類、検知時刻から合成する。同じ出来事から行を二重に生成しない。

| 契機 | unread |
| --- | --- |
| 行の生成 | 立てる（List がオフの種類、Hidden の対象なら立てない） |
| `read`（行を選んだ、または開いた） | 下ろす |
| `read_all`（CLI の `read --all`） | Snooze 中の PR の行を除く、そのアカウントのすべての行で下ろす |

行の状態は未読だけである。`popover_opened` と `popover_closed` は行の状態を変更しない。

### カードの状態

- 表示の判定は次の順で行う。読めなくなった PR と、Exclusions で Hidden のリポジトリの PR は表示しない。Snooze 中は Snoozed セクションに表示する。それ以外は、未読の行があるかレビュー待ちなら表示する。残りは「カードが出る・消える条件と監視期間」に従う（消える条件はポップオーバーを閉じたときに反映する）。
- 並びは、開いている PR（Draft を含む）を先に、Merged と Closed を後ろにし、それぞれの中で `Recently updated` なら PR の `updatedAt` の降順、`Recently added` ならカードの追加時刻の降順とする。追加時刻はカードが初めて表示の条件を満たした時刻で、更新しない。セクションへの区別と並べ替えはアプリが行う（「PRs タブのセクション」）。
- レビュー待ち（`awaiting_review`）と `review_count` は、表示のたびに（`list` の応答と `account_changed` を生成するたびに）PR の今の状態、Snooze、Exclusions、チームの List から求める。disabled の owner の `review_count` は 0 で、アカウントの `review_count` は owner の値の和である。
- 消える条件を満たしても、ポップオーバーを開いている間に表示したカードは `list` に含め続ける（「カードが出る・消える条件と監視期間」）。
- Snooze は PR ごとの有無だけを保存し、戻る時刻を PR ごとに保存しない。解除は Mac の現在のタイムゾーンの Return time に行う。「Snoozed until」の表示は次の Return time から求める。Return time を変更すると、Snooze 中のすべての PR に反映する。

### 通知の判定

デーモンが行の生成時に通知の要否を判定し（表の Notify、owner の Notify、Skip draft pull requests、Exclusions）、結果を行に保存する。アプリの再起動で再通知しない。Snooze 中の PR の行は個別に通知せず、解除時のまとめ通知の対象として記録する。通知を渡す時点でも、owner の Notify、enabled、PR を読めるかを確認し、オフ、disabled、読めなくなった PR のいずれかなら通知せず記録を消去する。後からオンに戻しても、消去した分は通知しない。Mac のスリープ中に Return time を過ぎた場合は、復帰時に解除とまとめ通知を 1 回だけ行う。

デーモンは通知をアプリへ渡したかを記録する。渡せなかった通知は、アプリの再接続時に「macOS 通知」のまとめ方に従って通知する（owner ごとに 2 件以上なら `N new events` のまとめ通知）。Snooze の解除のまとめ通知を渡せなかった場合は、その対象の行もこの N に含め、`Back from Snooze` は通知しない。Snooze より前に渡せなかった通知は、Snooze 中は保留し、Return time の解除ではまとめ通知の対象に含め、手動の Unsnooze では記録を消去する。手動の Unsnooze は利用者自身の操作で、青い点とカードの未読で足りるためである。アプリの停止中に起きた出来事も、起動後の取得で検知した分を同じようにまとめる。渡した通知はアプリを再起動しても再通知しない。

### 定数

| 定数 | 値 |
| --- | --- |
| 状態ディレクトリ | `~/.local/state/shiibar-gh/`（`SHIIBAR_GH_STATE_DIR` で変更） |
| ログレベル | info（`SHIIBAR_GH_LOG` で変更） |
| アプリの再接続 | 1 秒から倍々、上限 30 秒 |
| 取得の失敗の再試行 | 5、10、20、40 秒と延ばし、以降は 40 秒を繰り返す。どの待ち時間も設定の間隔を超えない |
| 取得の失敗の帯と三角を表示するまで | 最初の失敗から 5 分 |
| 文字の大きさ（`text_size`） | 既定 12 pt、範囲 9〜18 pt の整数 |
| 状態ディレクトリの権限 | ディレクトリ 0700、DB 0600 |

## 未決

- [ ] `repo` スコープの classic PAT で statusCheckRollup の個々の CheckRun と、非公開リポジトリのマージキュー（mergeQueueEntry、タイムラインのイベント）を取得できるか。できれば失敗したチェックの名前を GitHub Actions の job から求める回り道をやめられる
- [ ] メンションの判定は、bodyHTML の `user-mention` のリンク（`class="user-mention"` と、ユーザーのページへの `href`）と `team-mention` のリンク（`class="team-mention"` と、チームの databaseId を表す `data-id`）に依存する。この HTML の形は API の仕様ではないので、GitHub が変更すると判定できなくなる
- [ ] 1 つの PR が同時にマージキューに 2 回追加されることがあるか、取り除きが追加の順と異なる順に起きることがあるか（Removed from merge queue の行の、キューに追加した人の対応に影響する。ドキュメントに記載がなく、確認していない）
- [ ] `GET /notifications` の応答に、SSO を承認していない organization の分が含まれず `X-GitHub-SSO` が付くか（ドキュメントは REST の応答一般について記載している。所有者は SSO の organization に属していないので確認できない）
- [ ] SSO の承認が必要という警告の動作全体（SSO を有効にした organization で確認できていない）
- [ ] 複数の owner にまたがる要求（状況の取得、通知）で、1 つの organization への 403（`X-GitHub-SSO` が承認の URL だけの形）を受けたとき、その 403 を owner に結び付けられない。今はその取得の失敗として扱い、`sso_required` の警告は付けない（「トークン」）
- [ ] `x-oauth-scopes` の `write:org` と `admin:org` が `read:org` を含むとみなしてよいか（docs.github.com の「Scopes for OAuth apps」は `user` の入れ子だけを明記している。2026-11-09 に確認。実装はこの 2 つを `read:org` とみなす）
- [ ] 通知の書き込みと配信の記録の間にデーモンが強制終了すると、次の再接続のまとめ通知で 1 件多く数える場合がある（M1 から引き継いだ既知の動作で、変更しない）
