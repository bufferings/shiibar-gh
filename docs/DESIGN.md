# shiibar-gh 設計書

shiibar-gh は、自分が関わっている GitHub の PR について「起きたこと」を知らせ、「自分がレビューする PR」と「自分の PR」を利用者が決めた順に並べる、macOS のメニューバーの個人用アプリ。画面デザインは docs/design のモックを正とする。

この版（0.4、M6）は、アプリが更新を知らせ、カードの配置と順番を利用者が決める形に変更する。タブを All、Review、Mine の 3 つにし、Activity タブ、Snooze、Exclusions、メニューバーの数字を廃止する。カードの表示と既読を連動させず、カードを一覧から除くのは Dismiss だけにする。興味の薄いリポジトリ、利用者、PR には Mute を付ける。0.3 のデータは、アカウントとトークンだけを引き継ぐ（「状態の保存」）。

## 概要とスコープ

このアプリの責務は 4 つ。気づく（自分に関係する出来事が起きた）、自分がレビューする PR と自分の PR を順番に並べる、その場所へ移動する、対応を終えた PR を一覧から除く。「何をどう修正するか」は Web の仕事で、アプリは詳細を持たない。

**基本の考え方**

- アプリは更新を知らせる（取得、未読の印、通知）。カードの配置と順番は利用者が決める。Review と Mine では、更新があってもカードは移動しない（All は選択した並びに従う）。
- カードの表示と既読を連動させない。既読にしただけでカードが一覧から除かれることはない。カードが一覧から除かれるのは、利用者が Dismiss したときと、マージまたはクローズされた PR を日数の経過でアプリが Dismiss したときだけである。これとは別に、disabled の owner の PR と、読めなくなった PR のカードは表示しない（「カードの表示と監視」）。
- 自分に宛てた出来事は必ず知らせる。メンションは Mute していても通知する。Dismiss したカードも、メンション、自分のコメントへの返信、自分へのレビューの依頼、再オープンで復帰する。
- アカウントは独立している。アカウントをまたぐ順番は持たない。

**対象**

- 自分が関わっている PR（作者、レビュアー、メンションされた、コメントした、assign された）。Issue は扱わない。
- **アカウント**（GitHub のログイン）ごとに扱う。アカウントごとにメニューバーのアイコン 1 つ、classic PAT 1 つ、ポップオーバー 1 つを持つ。
- アカウントの下に **owner**（組織または個人）と **Public** を登録する。owner は取得の単位と出来事の表の単位である。Public はアカウントごとに 1 つで、最初は存在せず、使用するときに追加する。
- 同じ owner を複数のアカウントに登録できる。ログインが違えば「関わっている PR」は別物であり、両方のアイコンに表示し、通知も別に行う。
- 画面の表記は英語だけ。GitHub にある用語は GitHub の表記のまま使用する。

**対象外**

- GitHub への書き込み（既読の同期も含めて一切しない）。
- GitHub Enterprise Server。
- プッシュの検知。
- 0.1 からのデータの移行。0.2 と 0.3 からは、アカウントとトークンだけを引き継ぐ。

## 画面構成

**メニューバー**。アカウントごとにアイコン 1 つ（幅固定。1 アカウントでも 1 つ）。絵柄は shiibar-gh のもので全アカウント同じで、アカウントの色（「アカウントの色」）で塗る。右上の青い点＝新しい出来事あり（「未読の消え方」）、三角＝注意（トークンの期限と無効、取得の失敗、上限による取得の停止、Keychain を読めない）。数字は表示しない。画像は絵柄を中央に配置し、点を角に少しはみ出させる（大きさは実機で決める）。アクセシビリティの文言は `shiibar-gh, <login>` で、青い点があれば `, unread` を、三角があれば `, needs attention` をこの順で後ろに加える（`shiibar-gh, bufferings-work, unread, needs attention`）。アカウントが 1 つもないときの文言は `shiibar-gh, no accounts` である。アカウントが 1 つもないときは、shiibar-gh のアイコンを 1 つだけ表示する。押すと「No accounts yet」「Add an account in Settings」と `Add account…` のボタン、⌄ のメニューを表示する。`Add account…` は設定画面を開き、Add account のシートを直接表示する。

**ポップオーバー**。幅 460px（文字の大きさが 12 のとき。「文字の大きさ」）。押したアカウントだけを表示する。ポップオーバーと常時表示ウインドウは同じ内容を表示し、レイアウトは 1 種類である。上から：

1. 見出し：アカウント名（前にアカウントの色の丸）、その下の行に `Updated 1 min ago` と API の使用量（細いバーとポイント。「レート制限」）、Open in window、Refresh、Settings、⌄ のメニュー（About shiibar-gh、Settings…、Quit shiibar-gh）。Updated は、そのアカウントの取得が最後に成功して終わった時刻である（「取得の成功と失敗」。成功したことがなければ `Not updated yet`）。警告があるときだけ黄色い帯（「警告の表示」）。ポップオーバーを開いている間と、常時表示ウインドウにフォーカスがある間は ⌘Q でも終了する。終了するとデーモンも止まる。
2. タブの行：**All｜Review｜Mine**（「タブ」）。各タブの名前の後ろに未読の数を表示する。右端に Dismissed の一覧を開くボタン（アイコンと、Dismiss しているカードの数。0 なら数を表示しない）。
3. 操作の行：検索欄（プレースホルダー `Search`。⌘F で移動する）。All タブでは続けて Group by、Then by、並びのポップアップボタン（どれも今の値を表示し、ツールチップは `Group by`、`Then by`、`Sort`。Then by が `None` のときは `Then by` と表示する）。幅に合わせて伸びるのは検索欄だけである。
4. カードの列。
5. キーのヒント（幅に収まらないときは 2 行に折り返す。「キーボード」）。

コントロールは macOS の標準のものを使用し、オンの色は OS のアクセントカラーで、アプリ側で固定しない。表示中のタブ、Group by、Then by、並び、グループの順番、折りたたみ、`+ N more PRs` の展開は、アカウントごとに記憶する。検索の文字は記憶しない（「キーボード」）。

### タブ

| タブ | 内容 | 自動で追加される PR | 順番 |
| --- | --- | --- | --- |
| `All` | 関係する PR のすべて（Dismiss している PR を除く） | 関係する PR のすべて | Group by（2 段）と並びに従う |
| `Review` | 自分がレビューする PR | レビューを依頼された PR（自分宛て、チーム宛て） | 区画と順位を利用者が決める |
| `Mine` | 自分がレビューしてもらう PR | 自分が作成した PR | 順位を利用者が決める |

- ポップオーバーとウインドウは、それぞれアカウントごとに最後に表示したタブを記憶し、開いたときにそれぞれ自分が最後に表示したタブを開く。
- タブの未読の数は、そのタブにあるカードのうち、青い未読の行（「未読の消え方」）を持つカードの数である。Mute の対象の灰色の未読は数えない。0 なら表示しない。All の数は、Dismiss していないすべてのカードから求める。
- 1 つの PR の配置先は、Review と Mine のどちらか 1 つだけ、または配置なしである。配置した PR も All に表示する。
- 0.3 の絞り込みのチップ（All、Authored by me、Assigned to me、Review requested）はない。同じ区別は、Review と Mine のタブ、および Group by の `Involvement` で行う。

### All

関係する PR をすべて表示する。Review または Mine に配置している PR のカードには、配置先のタグ（`Review · Waiting`、`Review · Done`、`Mine`、`Mine · Done`）を表示する。タグを押すと、そのタブを開き、そのカードを選択する。

**Group by**。2 段で、`Group by` と `Then by` のポップアップボタンで選択する。値はどちらも次の 5 つで、2 段に同じ値は指定できない（`Group by` で `Then by` と同じ値を選択すると、`Then by` は `None` になる）。`Group by` が `None` のときは `Then by` を選択できず、`None` とする。3 段以上はない。初期値は `Group by` が `Repository`、`Then by` が `None` である。1 段目のグループは帯の見出し、2 段目のグループは字下げした小さい見出しで表示する。

| 値 | グループ | 順番の初期値 |
| --- | --- | --- |
| `Owner` | owner ごとに 1 つ | 登録の順で、Public は最後 |
| `Repository` | owner/repo ごとに 1 つ | 名前の順。あとから現れたリポジトリは末尾に追加する |
| `Status` | `Open`、`Draft`、`Merged`、`Closed` | この順 |
| `Involvement` | `Review requested`、`Authored by me`、`Assigned to me`、`Others`。複数に該当する PR は、この順で先に該当した 1 つに属する。ただし自分が作成した PR は、チーム宛ての依頼があっても `Authored by me` に属する。`Others` はどれにも該当しない PR | この順 |
| `None` | グループを区別しない（見出しを表示しない） | — |

**グルーピングの設定**。`Group by` のメニューの末尾の `Grouping…` で、ポップオーバー（またはウインドウ）の中にシートを表示する。シートは `Group by` と `Then by` のポップアップと、選択中の 2 つの値それぞれのグループの一覧（`Order of Repository` など）を持ち、一覧の行をドラッグしてグループの順番を変更する。`Done` で閉じる。順番は、アカウントごとに、Group by の値ごとに記憶する。`Owner` の一覧は enabled の owner、`Repository` の一覧はこれまでにカードがあったリポジトリである。削除した owner は一覧から除く。

どの Group by でも、カードのないグループは表示しない。カードの有無は、検索を適用したあとのカードで判定する。

**並び**（アカウントごとに記憶する）は `Recently updated`（既定。PR の `updatedAt` が新しい順）と `Recently added`（カードの追加が新しい順）の 2 つである。いちばん内側のグループの中では、開いている PR（Draft を含む）を先に、Merged と Closed を後ろに並べ、それぞれの中で選択した並びに従う。Mute の対象のカードは、そのグループの末尾に、同じ規則で並べる。`Recently updated` では、出来事で `updatedAt` が進んだカードが上に移動する。選択中のカードは、移動しても選択を保つ。

アサインされた PR には `Assigned` の印を表示する。アサインされた PR は自動では配置しない（アサインの用途は人によって異なるため）。利用者が Review または Mine に配置する。

### Review

区画は上から `Doing`、`Todo`、`Waiting`、`Done` である。順番は注目する順で、作業の流れの順にはしない。4 つの区画は、カードがなくても見出しと破線の枠（`No pull requests`）を表示し、ドラッグしたカードをそこに移動できる。ただし、検索中と、Review に 1 枚もカードがないときは、空の区画を表示しない。

| 区画 | 内容 | 追加される条件 |
| --- | --- | --- |
| `Doing` | 今レビューしている PR | 利用者が移動する |
| `Todo` | これからレビューする PR | レビューの依頼で自動で末尾に追加する。All から利用者が追加した PR も末尾。Doing と Waiting から移動した PR は先頭 |
| `Waiting` | 相手の作業を待っている PR | 利用者が移動する |
| `Done` | 対応を終えた PR（マージまたはクローズされた PR と、利用者が移動した PR） | マージまたはクローズを検知した時点で、どの区画からでも自動で移動する。利用者も、開いている PR とマージまたはクローズされた PR を移動できる。マージまたはクローズされた配置なしの PR を `Add to Review` で追加するか、その PR のレビューの依頼の行を生成すると、直接 `Done` に配置する |

- レビューを依頼された PR は、自分宛てでもチーム宛てでも、Mute の対象でも、自動で `Todo` の末尾に追加する。契機は、Review requested または Review requested to my team の行を生成したとき（List がオンのとき。「表の適用」）である。そのため、チーム宛ての依頼を対象にするかどうかは、owner の `Review requested to my team` の List に従う。すでに Review または Mine に配置している PR、Dismiss している PR は、この規則では移動しない（Dismiss している PR の復帰は「Dismiss」）。マージまたはクローズされた PR は、`Add to Review` と同じく `Todo` ではなく Review の `Done` に配置する。`Done` の中の位置と n 日の起点は、配置なしの間の起点（「Dismiss」）のままで、新しく発見した閉じた PR では検知の時刻である。新しく発見した閉じた PR では、生成する行は復帰の契機の 4 つの行（「Dismiss」）だけなので、Review の `Done` に配置する契機は自分宛ての Review requested の行だけである。チーム宛ての依頼は行を生成せず、Review に配置しない。
- 一度 Review に追加した PR は、依頼が取り消されても、レビューを提出しても、そのまま残す。Review から取り除くのは利用者の操作（`Remove from Review`）だけで、取り除いた PR は配置なし（All だけ）になる。
- `Doing`、`Todo`、`Waiting` の中の順位と、区画の間の移動（`Done` への移動と `Done` からの移動を含む）は、ドラッグ＆ドロップ、右クリックのメニュー、キーで行う（「キーボード」）。`Done` へ移動するキーはない（D／T／W だけである）。メニューとキーで移動したカードは、`Todo` へは `Doing` と `Waiting` からの移動なら先頭に、それ以外（`Done` からの移動を含む）は末尾に配置する（ワイヤの `place` の既定と同じ）。
- `Done` の中は、カードが `Done` に入った時刻が新しい順に並べる。入った時刻は、自動の移動ではマージまたはクローズを検知した時刻、利用者の移動ではその操作の時刻である。順位は変更できない（⌥↑／⌥↓ と、`Done` の中のドラッグによる並べ替えはない）。`Done` へのドロップは、ドロップした位置に関係なく、この並びの規則で配置する。
- `Done` のカードは、並びの規則のほかは、ほかの区画のカードと同じく扱う。開いているか、マージまたはクローズされたかを問わず、ドラッグ（つまみ）、`Move to …`、D／T／W で `Doing`、`Todo`、`Waiting` へ（Mine では、ドラッグと `Move to Mine` で 1 本目の一覧へ）移動でき、`Remove from Review`／`Remove from Mine` で取り除ける（自分が作成した PR は Mine から取り除けない）。
- `Done` に移動したカードは、移動する前の区画と順位を記録し、再オープンによる復帰に使用する。配置なしから、または別のタブから `Done` に移動したカードは、`Todo` の末尾（Mine では 1 本目の一覧の末尾）を記録する。
- マージまたはクローズによる `Done` への移動は、状況の取得でマージまたはクローズを検知した時点の 1 回だけ行う（Reopened の行は出来事から生成し、配置とは独立である）。すでに `Done` にあるカードは `Done` に残り、入った時刻をその検知の時刻にする。利用者がマージまたはクローズされたカードを `Done` から他の区画へ移動したあとは、以降の取得で `Done` に戻さない。
- 再オープンを状況の取得で検知すると、`Done` にあるカードは記録した区画と順位に戻る。`Done` の外にあるカードは移動しない。再オープンのあと再びマージまたはクローズされたカードは、その検知の時刻に `Done` に入ったものとして並べ、n 日もその時点から改めて数える。自動の Dismiss の例外（Restore したこと、マージまたはクローズのあとの Mentioned と Reply in a thread I commented in の行。「Dismiss」）は、再オープンで終わる。
- `Done` のカードに新しい出来事があると、ほかの区画と同じく行を未読にして通知する。カードは `Done` に残り、配置は利用者が決める。レビューの依頼でも移動しない（上の規則）。
- 各区画で、Mute の対象のカードは区画の末尾に、利用者が付けた順位のまま並べる。Mute を解除すると、元の順位の位置に戻る。区画の中の表示の順（ワイヤの `placement.position`）は、Mute の対象でないカードを先にした、この並びである。
- ⌥↑／⌥↓ による順位の変更は、表示の順で Mute の対象でないカードの間だけで行い、Mute の対象のカードでは行えない。D／T／W と `Move to …` は Mute の対象のカードにも行え、移動先の区画の末尾の Mute の対象のカードの間に配置する（`Todo` の先頭への移動でも、Mute の対象のカードの先頭に配置する）。
- 自動の追加（レビューの依頼、自分が作成した PR）は、Mute の対象でないカードの末尾に配置する。Mute の対象の PR は、Mute の対象のカードの末尾に配置する。

### Mine

- 自分が作成した PR を、自動で末尾に追加する。順位を付けた 1 本の一覧で、末尾に `Done` の区画がある。1 本目の一覧は見出しを持たない。
- アサインされた PR などは、All から利用者が追加できる（`Add to Mine`。末尾に追加する。マージまたはクローズされた PR は直接 `Done` に配置する）。利用者が追加した PR は `Remove from Mine` で取り除ける。自分が作成した PR は取り除けず、Review にも配置できない。
- マージまたはクローズされた PR は、検知した時点で自動で `Done` に移動する。新しく発見した閉じた PR（記録のない PR。「Dismiss の記録」）のうち自分が作成した PR は、Mine の `Done` に配置する。自分が作成していない閉じた PR は配置なしにする（自分宛ての Review requested の行を生成した PR は Review の `Done`。「Review」）。どちらも `Done` の中の位置と n 日の起点は、その検知の時刻である。`Done` の並び、`Done` への移動と `Done` からの移動、Mute の対象の位置と順位の規則は Review と同じである。Mine の `Done` へは、ドラッグ＆ドロップとメニューの `Move to Done` で移動し、Mine の `Done` から 1 本目の一覧へは、ドラッグとメニューの `Move to Mine` で移動する（末尾に配置する）。
- Mine の 1 本目の一覧と `Done` は、カードがなくても破線の枠（`No pull requests`）を表示し、ドラッグしたカードをそこに移動できる。ただし、検索中と、Mine に 1 枚もカードがないときは、空の区画を表示しない。
- 同時に複数の PR を末尾に追加するとき（owner を追加した直後など）は、作成の古い順に追加する。Review の `Todo` への自動の追加も、依頼の古い順に追加する。

### 区画の表示数

Review と Mine のすべての区画、および All のいちばん内側のグループ（`None` では 1 本の一覧）で、6 枚以上あるときは上位 5 枚を表示し、残りを `+ N more PRs` の 1 行（1 件なら `+ 1 more PR`）にまとめる。例外はない。

- `+ N more PRs` を押すと展開し、その行の表示を `Show less` に切り替える。区画の見出しにも、展開中だけ `Show less` を表示する（見出しのない Mine の 1 本目の一覧では、末尾の行だけ）。`Show less` を押すと元に戻す。展開の状態は、アカウントごとに、区画の鍵ごとに記憶する。区画の鍵は、Review と Mine ではタブと区画、All では（Group by の値、Then by の値、1 段目のグループの鍵、2 段目のグループの鍵）の組である（2 段目がなければその部分は空）。
- まとめた中に青い未読のカードがあれば、`+ N more PRs` の行に青い点を表示する。灰色の未読だけなら灰色の輪を表示する。
- 検索の文字があるときはまとめず、一致したカードをすべて表示する。
- 区画とグループの見出しは、名前と PR の数（`6 PRs`）、折りたたみの山形である。数は検索に依存しない。見出しを押すと区画全体を折りたたむ。折りたたみは、展開と同じ区画の鍵で、アカウントごとに記憶する（All の 1 段目のグループを折りたたむときは、2 段目のグループの鍵を空にした組を使用する）。区画の中をスクロールさせる方式は採用しない。Review と Mine の区画の見出しは、All の 1 段目のグループと同じ帯の見出しである。

### Dismissed の一覧

タブの行の右端のボタンで開き、タブの内容の代わりに表示する。見出しは `← Dismissed` と PR の数、その下に `Dismissed pull requests are removed after 7 days.`（7 は「Dismiss」の m）。カードは Dismiss した時刻が新しい順に並べる。カードは状態ラベル、owner/repo #番号、作者のアバター、タイトル、残りの日数（`6 days left`。1 日未満は切り上げ、1 なら `1 day left`。期限を過ぎてもポップオーバーを開いているために除去を延ばしている間は `0 days left`）、`Restore` のボタン、常に表示する開くアイコン（PR のページを開く）で構成し、行と状況アイコンを表示しない。一覧を開いている間は、どのタブにも下線を付けず、Dismissed のボタンを選択中の表示にする。Dismissed の一覧は、タブとは別に自分の検索の文字を持ち、一覧を閉じたときに消す。`←` または Esc でタブに戻る。ポップオーバーを閉じると、次に開くときはタブを表示する。Dismiss しているカードがなければ `No dismissed pull requests` を表示する。disabled の owner の PR と読めなくなった PR は、Dismiss していてもこの一覧と数に含めない（「カードの表示と監視」）。

### カード

**カードの見出し（3 行）**

| 行 | 左から |
| --- | --- |
| 1 | ドラッグのつまみ ⋮⋮（Review と Mine の、`Done` を含むすべての区画。Mute の対象のカードを除く）、PR の状態ラベル（Mergeable 緑／Draft 灰／Merged 紫／Closed 赤。Open は無印）、owner/repo #番号、`Review requested` の印（レビュー待ちの間だけ）、`Assigned` の印（自分がアサインされている間だけ）、`Muted` の印（Mute の対象の間だけ）、右端に状況アイコン 3 つと開くアイコン |
| 2 | 作者のアバター、タイトル |
| 3 | 左に配置先のタグ（All だけ）と base ← head、右に `Dismissed in 2 days`（自動の Dismiss の予定があるカードだけ）と `opened 3 days ago by alice · updated 2 hr ago`（薄い文字。ボードは `3d ago` と略記する）、右端に Dismiss の × |

`Review requested` の印は、薄いオレンジの地に濃いオレンジの文字の小さなラベルで、PR がレビュー待ち（「レビュー待ちの定義」）の間だけ表示する。行の既読とは独立で、行を既読にしても残る。`Assigned` と `Muted` の印は、枠線だけの小さなラベルである。

3 行目の右の部分は、PR の作成時刻（GraphQL の `createdAt`）、作者、更新時刻（`updatedAt`）である。相対時刻の書式は行の meta と同じ（`5 min ago`、`2 hr ago`、`3 days ago`）で、マウスを乗せると正確な日時を表示する。作者を特定できない PR は `by …` を省く。幅が足りなければ、右の部分を省略せずに 4 行目に折り返す。× は、この部分の右に付く。

`Dismissed in 2 days` は、自動の Dismiss（「Dismiss」）の予定があるカード（ワイヤの `auto_dismiss_at` が `null` でないカード）にだけ、時刻の直前に、時刻と同じ 11pt（文字の大きさに合わせて拡大縮小する）の薄い文字で表示する。日数は `auto_dismiss_at` までの日数を切り上げた値で、1 日未満と期限を過ぎた場合は 1 日とする（`Dismissed in 1 day`）。文字は選択できない。マウスを乗せると、Review または Mine の `Done` に配置したカードでは `Automatically dismissed 3 days after it is merged or closed. Move it out of Done to keep it.` を、配置なしのカードでは 1 文目の `Automatically dismissed 3 days after it is merged or closed.` だけを表示する（3 は設定の n で、1 なら `1 day`。配置なしのカードには出る先の `Done` がないため）。予定のないカードには何も表示しない。

状態ラベルと同じ色の縦線をカードの左端にも引く（色だけにしない）。アバターは作者の GitHub のアイコンの画像（GraphQL の `author.avatarUrl`）で、マウスを乗せると作者の login をツールチップで表示する。

Mute の対象のカード（「Mute」）は、すべての文字（タイトル、リポジトリ名、行）を灰色にし、タイトルを太字にしない。ただし Mentioned の行は通常の文字の色と青い点のままにする。灰色は Mute の対象だけに使用する。

**状況アイコン 3 つ**。順番固定 Review／Checks／Base。塗りの ✓ 緑、塗りの × 赤、点線の ◌ 灰。文字は付けない。マージまたはクローズされた PR には表示しない。

| 列 | ✓ | ◌ | × | 値の元 |
| --- | --- | --- | --- | --- |
| Review | Approved | Review required | Changes requested | reviewDecision（null なら最新のレビューから求める） |
| Checks | Passed | In progress（None は空） | Failed | statusCheckRollup |
| Base | Up to date | Behind | Conflicts | mergeable / behindBy |

Base は、behindBy を取得できなければ Conflicts または空とする。mergeable が UNKNOWN なら前回の値を保つ。

Mergeable は mergeStateStatus が CLEAN のときだけで、自前で計算しない。詳細（誰が、どのチェックが、何コミット）は載せず、押すと各軸の場所へ移動する。移動先は、Review と Base が PR のページ、Checks が PR の Checks のページ（`/checks`）である。この行から「誰の番か」は判断しない。

**レビュー待ちの定義**。レビュー待ちは PR の状態であり、行の性質でも配置でもない。レビュー待ちの PR とは、開いている PR のうち、自分が作成した PR を除き、GitHub の今のレビュー依頼（reviewRequests）に自分または自分のチームが含まれ、最新の依頼のあとに自分のレビューがないものを指す。自分が作成した PR は、チーム宛ての依頼があってもレビュー待ちにならない。カードの `Review requested` の印だけがこの状態を示す。Review タブへの追加は、この状態ではなく依頼の行で決まる（「Review」）。

- 自分宛ての依頼は、reviewRequests に自分がいれば対象にする。Review requested の行の有無と、Review requested の List のオンとオフは条件にしない。
- チーム宛ての依頼は、その owner の Review requested to my team の List がオンのときだけ対象にする。自分宛てと同じく、最新の依頼のあとに自分がレビューしていれば対象にしない。
- 自分のレビューは、取得している PR のレビュー（author が自分のもの）から判定する。レビューの投稿によって GitHub が依頼を取り消すかは確認していないので、この条件で補う。最新の依頼の時刻は、行とは別に PR ごとに保存する「自分または自分のチームへの最新の依頼の時刻」で判定する。この時刻は、取得した REVIEW_REQUESTED_EVENT（自分宛て、または自分が属するチーム宛て）から更新し、行を生成しない場合（List がオフ、Dismiss している PR、行の削除のあと）も更新する。時刻が分からないときは、自分のレビューが 1 つでもあれば対象にしない。
- Mute はレビュー待ちに関係しない。

依頼が取り消されるか、最新の依頼のあとに自分がレビューすると、レビュー待ちではなくなる（再び依頼されると戻る）。状況アイコンの赤はレビュー待ちに関係しない。

**押したときの動作**。カード内に開閉はない。

- カードの見出しと行は、クリックで選び（行は既読になる。「未読の消え方」）、右クリックでその項目を選んでから（行なら既読にしてから）メニューを表示する（「キーボード」）。
- カードの見出しと行は、右端に開くアイコンを常に表示する。押すと、カードの見出しは PR のページを、行はその出来事の場所を開く（⏎ と同じ。行は既読になる）。ダブルクリックで開く操作はない。
- カードのタイトル、owner/repo #番号、ブランチ（`base ← head`）、時刻、行のラベル、行の補足（actor、時刻、`for … team` など）、行の本文は、macOS の標準の操作で文字を選択できる。選択の範囲は、これらの 1 つの中に限る。クリックはカードまたは行の選択、ダブルクリックは単語の選択、ドラッグは範囲の選択である。選択した文字は ⌘C と右クリックのメニューの `Copy` でコピーする。文字の選択は、別の項目を選んだとき、またはポップオーバーを閉じたときに解除する。
- カードの移動のドラッグは、つまみ ⋮⋮ から始める。つまみの上では、ポインタを開いた手の形にする。ドラッグ中は、カードの見出し（状態ラベル、owner/repo #番号、タイトル、ブランチ）をカードと同じ幅でポインタに追従させ、元の位置のカードは薄く表示する。Review では区画の間に、Review と Mine では `Done` との間にも移動できる。All と Dismissed の一覧ではドラッグで移動しない。`Done` の中では並べ替えない。Mute の対象のカードはドラッグできない（つまみを表示しない）。
- ドロップで挿入できるのは、区画の中の Mute の対象でないカードの間（先頭と末尾を含む）だけで、Mute の対象のカードは常にその後ろに並ぶ。Mute の対象のカードの上、区画の見出しの上、折りたたんだ区画の上、`+ N more PRs` の行の上にドロップすると、その区画の Mute の対象でないカードの末尾に配置する。`Done` には、見出し、カード、`+ N more PRs` の行、空の区画の枠のどこにドロップしても、`Done` の並びの規則（「Review」）に従って配置する（挿入の線は先頭のカードの上に表示する）。`Done` のカードを同じ `Done` にドロップしても移動しない。Dismissed の一覧にはドロップできない。
- 状況アイコンは押すと Web のその場所へ、開くアイコンは押すと PR のページへ、× は押すとその PR を Dismiss、配置先のタグは押すとそのタブのカードへ移動する。区画の見出しはクリックで折りたたみ、`+ N more PRs` と `Show less` はクリックで展開と復帰を行う。ホバーでしか表示されない操作は設けない。

**操作の反映**。操作は 2 種類に区別する。

- 手元で完結する操作（カードの配置と順位の変更、Dismiss、Restore、Mute と解除、既読。GitHub には何も送信せず、デーモンが DB を更新するだけの操作）は、アプリが要求を送ると同時に結果を画面に反映する。ドラッグ＆ドロップでは、カードを移動先に配置した状態のまま確定を待つ。デーモンが失敗を返した場合（デーモンに接続できない場合を含む）だけ、元の表示に戻し、操作の失敗の帯に `Couldn't <動詞>: <理由>`（`Couldn't dismiss: daemon not running` の形。理由はデーモンの `error`、接続できなければ `daemon not running`）を表示する。この帯は警告の黄色い帯とは見た目を区別し、両方があるときは警告の帯の下に表示する。この帯は次の操作か 10 秒の経過で消す。動詞は次のとおりである。

| 操作 | 動詞 |
| --- | --- |
| Dismiss | `dismiss` |
| Restore | `restore` |
| Mute | `mute` |
| Mute の解除 | `unmute` |
| 区画の間の移動と順位の変更（ドラッグ＆ドロップ、`Move to …`、⌥↑／⌥↓、D／T／W） | `move` |
| `Add to Review`、`Add to Mine` | `add` |
| `Remove from Review`、`Remove from Mine` | `remove` |
| 既読（行の選択、開く、⇧R） | `mark as read` |

- GitHub との通信が必要な操作（Refresh、アカウントの追加、トークンのテスト、owner の追加）は、押した直後に処理中の表示（Refresh のボタンは進行中のインジケーター、設定画面は「設定画面の規則」の 8）にし、応答を受信した時点で結果を反映する。

アプリは `account_changed` を受信するたびに、待ち時間を設けずに一覧を再取得する（再取得の間に受信した分は、再取得のあとに 1 回だけ再取得する）。Mute の一覧を読み込み済みのアカウントでは、Mute の一覧も再取得する（設定画面と CLI で変更した Mute を、メニューと手元の Mute の反映に使用するため）。手元の Mute と解除の反映は、対象のカード（その PR、そのリポジトリの PR、その利用者が作成した PR）と、利用者の Mute ではその利用者の行だけを変更し、ほかのカードと行はデーモンから受信した状態のままにする。

**Open in window**。見出しのボタンで、同じ内容を小さなウインドウ（NSPanel）に表示する。アカウントごとに 1 つ、位置と大きさを記憶する。ウインドウの見出しの右側（Refresh、Settings、⌄ の並びの先頭）にピンのボタン（ツールチップ `Keep on top`）を表示する。オンは塗りつぶし（青）、オフは線だけで、オンの間ウインドウを常に手前に表示する。押すとそのウインドウがすぐ切り替わる。値はウインドウの位置と一緒にアカウントごとに記憶し、既定はオンである。ピンのボタンはポップオーバーには表示しない。同じアカウントのポップオーバーとウインドウは、表示中のタブ、Dismissed の一覧を開いているか、検索の文字、選択、文字の選択を別に持つ。Group by、Then by、並び、グループの順番、折りたたみ、`+ N more PRs` の展開はアカウントごとの状態で、両方に共通である。

**文字の大きさ**。設定の Text size（`text_size`）は本文の文字の大きさ（pt）で、全アカウントのポップオーバーと常時表示ウインドウに共通に適用する。メニューバーのアイコンと設定画面には適用しない。ほかの文字、行の高さ、アバターは、12 に対する比率で連動する。ポップオーバーは幅も比率で連動する。常時表示ウインドウは記憶した大きさを優先し、内容だけを比率で連動させる。ポップオーバーとウインドウでは、⌘= で 1 pt 大きく（⌘+ も同じ）、⌘− で 1 pt 小さく、⌘0 で 12 に戻す。18 での ⌘= と 9 での ⌘− は何もしない（アプリは要求を送らない）。キーで変更した値も設定の値として保存する（範囲と範囲外の入力の文言は「設定項目」）。

**アカウントの色**。選択肢は None、Red、Orange、Yellow、Green、Blue、Purple（Finder のタグと同じ並び）。塗る先はメニューバーのアイコンと、アカウント名の前の丸（ポップオーバーの見出し、設定画面の一覧）だけである。None はアイコンに色を付けず、ほかのメニューバーのアイコンと同じ色（ライトでは黒、ダークでは白）にし、丸は文字と同じ色にする。値は macOS のシステムカラー（systemRed など）を使用し、ライトとダークで自動的に切り替わるものにする（最終の見え方は所有者が実機で確認する）。初期値は、アカウントが 0 件のときに追加したアカウントが None、2 つ目からは Red → Orange → Yellow → Green → Blue → Purple の順で未使用の色を割り当て、すべて使用済みなら Red から再び巡回する（重複を許す）。削除して再び追加したアカウントは新規として扱う。ポップオーバーの背景は全アカウント同じで、owner と Public に色はない。

**通常のアプリへの切り替え**。常時表示のウインドウと設定画面のどちらかが存在する間だけ、アプリは通常のアプリとして動作する。Dock と ⌘Tab にアプリが表示され、画面上端にアプリのメニューを表示する。両方が閉じると常駐の状態に戻り、どちらも表示しない。メニューはアプリのメニューと Edit の 2 つである。アプリのメニューは About shiibar-gh、Settings…（⌘,）、Close Window（⌘W。閉じるウインドウがなければ無効）、Quit shiibar-gh（⌘Q）で構成し、Quit は ⌄ のメニューの Quit と同じくデーモンも止める。Edit は Undo、Redo、Cut、Copy、Paste、Select All である。Dock のアイコンを押すか ⌘Tab で切り替えると、開いているウインドウを前面に表示する。shiibar-cc の DESIGN.md の同じ規則にならう（shiibar-cc は設定画面を対象に含めない）。

## 行の種類と状態

カードの下に、その PR の出来事を行で並べる（新しい順）。出来事 1 件が 1 行で、macOS の通知は行から生成する出力である（複数の行を 1 件の通知にまとめることがある）。行は、owner ごとの **出来事の表**（「設定項目」の Notifications タブ。種類ごとに List／Notify の 2 つのチェック）に従って生成する。行はすべて「起きたことの記録」で、未読の点、種類のアイコン、ラベルを持つ。

| 種類 | 既定（List／Notify） | 内容 |
| --- | --- | --- |
| Review requested | ✓✓ | 自分にレビューが依頼された |
| Review requested to my team | ✓✓ | 自分が属するチームにレビューが依頼された |
| Mentioned | ✓✓ | 自分がメンションされた |
| My team mentioned | ✓✓ | 自分が属するチームがメンションされた |
| Comment on my PR | ✓✓ | 自分の PR に他の人がコメントした |
| Comment on other PRs | ✓✓ | 他の人の PR の会話欄に、自分以外の人がコメントした |
| Reply in a thread I commented in | ✓✓ | 自分がコメントしたスレッドに返信があった |
| Reply in a thread I was mentioned in | ✓✓ | 自分または自分のチームがメンションされたスレッドに、そのメンションより後の返信があった |
| Reaction to my comment | ✓✓ | 自分のコメントに Reaction が付いた |
| Approved | ✓✓ | 自分の PR が承認された（承認のレビュー 1 件につき 1 行） |
| Changes requested | ✓✓ | 自分の PR が Changes requested になった |
| Checks failed | ✓✓ | 自分の PR のチェックが失敗した |
| Checks passed | ✓✓ | 自分の PR のチェックが、成功でない状態のあとに成功した |
| Conflicts | ✓✓ | 自分の PR が base と衝突した |
| Mergeable | ✓✓ | 自分の PR が Mergeable になった |
| Added to merge queue | ✓– | マージキューに追加された |
| Removed from merge queue | ✓✓ | マージキューから取り除かれた |
| Merged / Closed | ✓– | マージまたはクローズされた |
| Reopened | ✓✓ | 再オープンされた |

表の見出しは Reviews and mentions（上 4 行）、Comments（次の 5 行）、My pull requests（次の 6 行）、Any pull request（残り）である。

**表の適用**。List は一覧に表示するか、Notify は macOS の通知をするかを決める。List をオフにすると Notify もオフになる。List がオフの種類の Notify をオンにする要求は `invalid` で拒否する。List を再びオンにしても、Notify はオフのままである。Notify は行を生成する時点の表の値で決め、行に保存する。あとから表を変更しても既存の行は変更しない。List は表示の絞り込みなので、変更はすぐ反映する。List がオフの間も行は記録し（未読なし、通知なしで保存する）、未読と通知の対象にしない。List をオンに戻すと、オフの間に記録した行を既読の行として表示し、さかのぼって通知しない。List がオフの間に記録した行は、Review への自動の追加（「Review」）、Dismiss からの復帰と自動の Dismiss の例外（「Dismiss」）の契機にしない。この 3 つは行を生成した時点の List で決め、あとから List をオンに戻しても契機にしない。20 件の上限と `+ N more`（「カードの中の行」）は今の List に従い、今 List がオフの種類の行を数えない。List をオンに戻すと、オフの間に記録した行も数える。今 List がオフの種類の行は、それらの行の中で同じく PR ごとに新しい 20 件までを保持する（「カードの中の行」）。`older_rows` は今の List に従わず、その PR の行を削除したことがあるかを示す。Review requested to my team の List は、チーム宛ての依頼をレビュー待ちに数えるかも決める（「レビュー待ちの定義」）。

**行の見た目**。行は先頭に未読の点（未読のときだけ）と種類のアイコン、右端に開くアイコンを持つ。点は青い塗りで、Mute の対象の行（「Mute」）では灰色の輪にする。既読になると点を除くだけで、行を薄く表示しない。

**Comment と Reply の対象**。Comment on my PR の行は、自分の PR に他の人が投稿した会話のコメント、レビューの本文、インラインコメントから、1 コメントにつき 1 行を生成する。Approve のレビューの本文も含める。本文付きで変更を求めるレビューは、Changes requested の行と Comment の行の両方を残す。本文付きの承認も同じく、Approved の行と Comment の行の両方を残す。Comment on other PRs の行は、他の人の PR の会話のコメント（自分以外が投稿したもの）から、1 コメントにつき 1 行を生成する。レビューの本文とインラインコメントは対象にしない。Reply の 2 種類の行は、自分がコメントしたスレッドへの返信と、スレッドで自分がメンションされたあとの返信から生成し、どの PR でも対象にする。ここでのスレッドは、コードの行に付くレビューのスレッドを指す。Comment と Reply の両方に該当するコメント（自分の PR の、自分がコメントしたスレッドへの返信）は、Reply の行だけを生成する。Mentioned と Comment または Reply の両方に該当するコメントは、Mentioned の行だけを生成する。Bot の投稿を特別扱いしない。Bot は利用者と同じく、投稿の内容で行の種類を決める。Bot の行を灰色にして通知を止めるには、その Bot を Mute する（「Mute」）。

未読のメンションは本文 3 行、それ以外は 1 行。本文は、改行と連続する空白を 1 つの空白にまとめて表示する（`bodyText` は「The body rendered to text」で、Markdown の記号を含まない。公開スキーマで確認）。

**未読の消え方**。役目は「気づいていない出来事がある」を示すことだけ。行は操作で既読にする。カードの表示は既読に連動しない。

- 行を選んだ時点（↑↓、クリック、右クリック）で、その行を既読にする。⏎、開くアイコン、右クリックのメニューの `Open on GitHub` で行を開いたときも既読にする。このとき、アプリは URL を開くとともに `read` を送る。
- ⇧R（右クリックのメニューの `Mark all as read`）は、表示中のタブのすべての行を既読にする。検索を適用したあとの行で、折りたたんだ区画の行、`+ N more PRs` にまとめたカードの行、カードの中の `+ N more` にまとめた行、Mute の対象の行を含む。アプリは `read` に行の id を列挙して送る。ワイヤの `read_all` と CLI の `read --all` の範囲はこれと異なる（「ワイヤ形式」）。
- ポップオーバーを閉じただけ、または常時表示ウインドウを閉じたかフォーカスが外れただけでは既読にしない。macOS の通知を押したかは関係しない。未読に戻す操作はない。
- 青い未読の行とは、未読の行のうち、Mute の対象でない行と、Mute の対象でも Mentioned の行である。Dismiss している PR の行、読めなくなった PR の行、disabled の owner の行は、未読でも数えない。
- メニューバーの青い点は、青い未読の行が新しく生じたときに付き、ポップオーバーを開いた時点（常時表示ウインドウにフォーカスが移った時点を含む）で消える。常時表示ウインドウは、フォーカスがある間を開いている、フォーカスがない間を閉じているとして扱う。Mute の解除と Restore（CLI を含む）で青い未読の行が生じたときも付ける。ポップオーバーを開いている間と、常時表示ウインドウにフォーカスがある間は、どの契機でも付けず、閉じたときに未読の行が残っていても付けない。
- レビュー待ちは行の既読と独立なので、Review requested の行を既読にしても `Review requested` の印は残る。Checks／Conflicts／Mergeable は状況アイコンとラベルに残る。

状況アイコンは「今の状態」、行は「起きたことの記録」。Checks が落ちて回復すればアイコンは Passed に戻り、Checks failed の行は残り、Checks passed の行を生成する。再び落ちれば新しい Checks failed の行を生成する。

**Review requested の行**。Review requested と Review requested to my team の行は、ほかの行と同じく起きたことの記録で、通常の規則で既読にする。今もレビューを待っているかは行ではなく PR の状態で判断する（「レビュー待ちの定義」）。再び依頼された場合は新しい行を生成する。

**チーム宛ての依頼とメンション**。チームの所属はアカウントのトークンで取得する（「API の使い分け」）。Review requested to my team の List がオフの owner では、チーム宛ての依頼を行にせず（記録はする）、その owner の検索に `user-review-requested:@me` を使用する。ほかの検索で発見した PR のチーム宛ての依頼は、記録だけにする。

**カードの中の行**。この節の行は今 List がオンの種類の行で、今 List がオフの種類の行は表示せず、数えない（List をオンに戻すと、オフの間に記録した行も表示し、数える。「表の適用」）。行は PR ごとに新しい 20 件まで保持し、それより古い行は既読かどうかに関係なく削除する。今 List がオフの種類の行も、記録の量を抑えるため、それらの行の中で PR ごとに新しい 20 件までを保持し、古い行を同じく削除する（List がオンの種類の 20 件とは別に数える）。削除した行は鍵（「行の状態遷移」）だけを記録し、同じ出来事を再取得しても行を再生成しない。カードには新しい 3 件の行を表示し、4 件以上あれば残りを `+ N more`（1 件なら `+ 1 more`）の 1 行にまとめ、押すと展開する。既読かどうかは、表示する行の数に関係しない。まとめた中に青い未読の行があれば `+ N more` の行に青い点を、灰色の未読の行だけなら灰色の輪を表示する。展開の状態は記憶せず、ポップオーバーを閉じると（常時表示ウインドウは閉じるかフォーカスを失うと）3 件の表示に戻る。行を削除したことがある PR（ワイヤの `older_rows`。削除した行の種類と今の List は問わない）では、展開した一覧の末尾に `Older activity on GitHub` の行を表示し、押すと PR のページを開く。

**Reaction の行**。自分のコメント（会話のコメント、レビューの本文、レビューコメント、PR の本文）の Reaction を種類ごとの件数で検知し、増えた種類ごとに 1 行を生成する。1 回の取得で同じ種類が複数増えた場合は 1 行で件数を表示する（`👍3`）。行の時刻は検知した時刻とする。件数が減っただけのときは行を生成しない。Reaction を削除して再度付けると新しい出来事として扱う。自分が付けた Reaction は件数から除く。監視の外で増えた分は行にせず、監視が戻った時点の件数を基準にする（「監視」）。監視中の PR の自分のコメントは、初めて集めたときの件数を基準にする。ただし、その owner の前回の取得より後に投稿されたコメントは 0 を基準にする。

**Approved の行**。自分の PR への承認のレビュー（state が APPROVED で、author が自分でない）1 件につき 1 行を生成する。PR 全体の判定（reviewDecision）が変更されたかは問わない。承認した人を表示し、本文を持たない。押すとそのレビューを開く。本文付きの承認は Comment on my PR の行も生成する（「Comment と Reply の対象」）。

**状態変化の行**。Changes requested、Checks failed、Checks passed、Conflicts、Mergeable の行は、開いている自分の PR の値の変化を状況の取得で検知したときに生成する。Changes requested は `changes_requested` 以外の値から `changes_requested` に、Conflicts は `conflicts` 以外の値から `conflicts` に、Mergeable は偽から真に変化した場合である。すでに `changes_requested` の PR で別のレビュアーが変更を求めた場合は、値が変化しないので行を生成しない。PR を初めて検出した時点では前回の値がないので行を生成しない。

Checks の行は、確定した結果どうしを比較する。確定した結果は Checks の値の `passed` と `failed` で、`pending`（実行中）と `none`（チェックなし）は結果として数えない。デーモンは PR ごとに、前回の取得で観測した Checks の値、前回の確定した結果（`passed`、`failed`、なし）、その結果を観測したときの head のコミット（GraphQL の `headRefOid`。公開スキーマで `GitObjectID!` と確認、2026-11-13）を保存する。今回の値が `passed` または `failed` で、前回の取得で観測した値と異なるか、head のコミットが前回の確定した結果のときと異なれば、新しい確定として扱う（実行中の状態を取得の間に観測できなかった場合も、プッシュのあとの結果を区別するため）。新しい確定が `failed` なら、前回の確定した結果に関係なく Checks failed の行を生成する（修正をプッシュして再び失敗した場合も生成する）。新しい確定が `passed` で、前回の確定した結果が `passed` でない（なし、または `failed`）場合だけ Checks passed の行を生成する。成功が続く間は生成しない。同じ取得で同じ PR に Mergeable の行も生成する場合は、Checks passed の行を生成せず、Mergeable の行だけにする。PR を初めて検出した時点、監視開始時刻を設定した時点、Dismiss から復帰して状況の取得を再開した時点では、その時点の値と（`passed` または `failed` なら）確定した結果を保存するだけで、行を生成しない。そのため、実行中の状態で検出した PR が初めて成功で確定した場合は Checks passed の行を生成し、成功で検出した PR では生成しない。

行の時刻は検知した時刻とする。本文は、Checks failed が最初に失敗したチェックの名前とほかに失敗したチェックの数（`+N`）、Changes requested が最初のレビュアーのログイン名とほかに変更を求めたレビュアーの数（`+N`）で、Conflicts と Mergeable は本文を持たない。Checks passed は本文を持たない。押すと開く場所は、Checks failed と Checks passed が Checks、Conflicts が Base、Changes requested が Review、Mergeable が PR のページである。失敗したチェックは、完了した GitHub Actions の job のうち結果が success、neutral、skipped 以外のものと、状態が FAILURE または ERROR の Commit status である。完了していない job と、PENDING または EXPECTED の Commit status は失敗に含めない。名前を取得できなければ本文を持たない。

**Merged、Closed、Reopened の行**。マージされた PR では、GitHub がタイムラインに MERGED_EVENT と CLOSED_EVENT の両方を生成する（0.3.0 の実データで、同じ時刻の 2 行として確認）。MERGED_EVENT と対になる CLOSED_EVENT（同じ PR の、MERGED_EVENT の時刻以降の CLOSED_EVENT）は、行にも通知にもしない。マージされた PR は再オープンできないので、MERGED_EVENT より前の CLOSED_EVENT（クローズ、再オープンのあとのマージ）は Closed の行にする。Reopened の行は REOPENED_EVENT から生成し、自分の操作かは問わない。自分が再オープンした場合は、行を既読で生成し、通知しない。この行も復帰の契機で、Dismiss しているカードは元の場所に復帰する（「Dismiss」）。

**監視開始より前の出来事**。owner の監視開始時刻は、owner を追加した時点、enabled にした時点、DB を空の状態で起動した時点である。この時刻より前の出来事は行にしない。監視開始時刻を設定するときは、その owner の PR の前回の値と Reaction の基準値を破棄する。出来事は、その owner で最後に取得に成功した時刻から 5 分さかのぼった時刻（監視開始時刻より前にはしない）以降のものを取得して行にする。PR を初めて検出した場合と、Dismiss の記録だけが残る PR を再発見した場合も同じで、それより前の出来事は行にしない。アプリの停止中に起きた出来事は、この時刻より後なので行になる。例外として、知らない開いている PR を初めて検出したときと、監視開始時刻を設定したときは、今も続いているレビュー依頼を、時刻に関係なく未読の行にする（取得の範囲が制限するのは、ほかの出来事の取得だけである）。この行は、依頼が監視開始時刻以降なら通知し、監視開始時刻より前なら通知しない。Dismiss の記録だけが残る PR、Dismiss しているカード、閉じた PR には、この例外を適用しない。これらでは、取得の範囲の中の依頼の出来事だけが行と復帰の契機になる。

## Dismiss

Dismiss は、対応を終えたカードを一覧から除く操作である。自分に宛てた出来事か再オープンがあれば、元の場所に復帰する。

- カードの ×、右クリックのメニューの `Dismiss`、⌫ で Dismiss する。Dismiss したカードは、All、Review、Mine から除き、`Dismissed` の一覧（「Dismissed の一覧」）に移る。
- `Dismissed` の一覧のカードは、Dismiss してから m 日（設定、初期値 7 日）が経過すると、一覧からも除く。それまでは `Restore`（ボタン、右クリックのメニュー、⌫）で元の場所に復帰できる。
- マージまたはクローズされた PR のうち、Review または Mine の `Done` にあるカードは、`Done` に入った時刻とマージまたはクローズを検知した時刻の遅いほうから n 日（設定、初期値 3 日）が経過すると、アプリが自動で Dismiss する。配置なしのカードは、検知の時刻から n 日で Dismiss する（`Remove from …` で取り除いたカードは、`Done` に入った時刻、`Done` の外から取り除いた場合は取り除いた時刻と、検知の時刻の遅いほうから数える）。利用者が `Done` から他の区画へ移動したカードは、`Done` の外にある間は自動では Dismiss せず、`Done` に戻すとその時点から n 日を数える。開いている PR は、`Done` にあっても自動では Dismiss しない。未読の行があっても Dismiss する。次のどれかに該当する PR は自動では Dismiss しない：マージまたはクローズのあとに Mentioned の行が生成された、マージまたはクローズのあとに Reply in a thread I commented in の行が生成された、利用者が `Restore` した。これらの例外は、PR が再オープンされるまで続く。再オープンのあと再びマージまたはクローズされると、その検知から n 日を数える。
- 自動の Dismiss の予定は、カードに `Dismissed in N days` として表示する（「カード」）。
- 開いている PR は自動では Dismiss しない。0.3 の「更新がないまま 14 日たつと表示しない」規則と、ほかの人の Draft を表示しない規則はない。ほかの人の Draft も、ほかの PR と同じく表示し、不要なら利用者が Dismiss する。
- 自動の Dismiss と、m 日の経過による一覧からの除去は、ポップオーバーを開いている間（常時表示ウインドウにフォーカスがある間を含む）は行わず、閉じたときに行う。
- 元の場所とは、Dismiss する前の配置先、区画、順位である。順位は Dismiss しても保ち、復帰したカードは、その区画の今のカードとの前後関係に従う位置に戻る。

**復帰の契機**。Dismiss しているカード（`Dismissed` の一覧にあるカードと、m 日が経過して一覧から除いたカード）は、次の 4 つの行のどれかを生成すると元の場所に復帰し、その行を未読にして通知する（通知の要否は「通知の判定」に従う）。自分が再オープンした場合もカードは復帰するが、Reopened の行は既読で生成し、通知しない（「Merged、Closed、Reopened の行」）。誰が Dismiss したか（利用者か、アプリか）で規則を変更しない。

| 契機 | 行 |
| --- | --- |
| メンション | Mentioned |
| 自分のコメントへの返信 | Reply in a thread I commented in |
| 自分へのレビューの依頼 | Review requested（チーム宛ては含まない） |
| 再オープン | Reopened |

- マージ済みの PR が復帰する場所は、Dismiss する前の場所（`Done`、または利用者が移動した `Done` の外の区画）である。Review と Mine の `Done` にあった PR が再オープンされた場合は、`Done` に入る前の区画と順位に復帰する。
- 元の場所の記録がない場合（一覧から除いたあとの PR。「Dismiss の記録」）は、新しく発見した PR と同じ扱いにし、配置の規則（「Review」「Mine」）に従って配置する。
- Dismiss している間は、上の 4 つ以外の行を生成しない（メンションのないコメント、Reaction、状態変化、マージとクローズなど）。復帰したあとも、Dismiss していた間の出来事は行にしない。Dismiss の記録だけが残る PR が復帰した場合と、新しく発見した閉じた PR を取り込んだ場合も同じく、取り込んだ時点より前の出来事は、あとの取得で再び受け取っても（取得の範囲の 5 分の重なりなど）行にしない。
- Dismiss しているカードは、出来事の検知だけを続ける。状況（チェックの結果など）と Reaction は取得せず、状況アイコンも表示しない。復帰した時点から取得を再開し、Reaction はその時点の件数を基準にする。
- Dismiss している間は状況を取得しないので、その間のマージとクローズは、カードが復帰したとき、または Restore したときに再開する状況の取得で検知する。ただし Dismiss しているカードを出来事の取得または検索の結果で調べたときに閉じていると分かった場合は、m 日の経過のときに Dismiss の記録を残さない。`Done` の中の位置と n 日の起点は、その検知の時刻である。Dismiss する前にマージまたはクローズされていた PR が復帰した場合も、その時点から改めて n 日の経過を数える。ただし Restore した PR は自動では Dismiss しない（上の例外）。閉じた PR が復帰の契機の行で復帰した場合と、新しく発見した閉じた PR では、n 日を数えるのは契機が Review requested または Reopened の行のときだけである。契機が Mentioned または Reply in a thread I commented in の行なら、その行はマージまたはクローズのあとの行なので、上の例外により自動では Dismiss しない。

**Dismiss の記録**。`Dismissed` の一覧から除いた PR は、カード、行、配置を削除する。開いている PR の場合だけ、Dismiss したことを示す記録（PR の id と、記録した時点の `updatedAt`）を残す。記録がないと、通常のコメントで更新された PR を、初めて発見した PR として All に表示してしまうためである。記録のある PR を検索で発見しても、上の 4 つの行を生成しない限り表示しない。閉じた PR は記録を残さず、閉じた PR の検索（「API の使い分け」）で再発見したときに、上の 4 つの行を生成した場合だけ表示する。記録は、その PR を次に調べたとき（検索の結果または出来事の取得）に閉じていると分かれば削除し、それ以外は、その owner またはアカウントを削除するまで残す。

## Mute

Mute は、興味の薄いものに付ける印である。解除するまで続く。カードは一覧に残り、通知だけを止める。対象は、リポジトリ、利用者、PR 1 枚の 3 種類で、アカウントごとに持つ。

| 項目 | Mute の対象 |
| --- | --- |
| カード | 灰色で、`Muted` の印を付け、区画（All はいちばん内側のグループ）の末尾に表示する。「区画の表示数」の規則により、多くの場合 `+ N more PRs` の中になる |
| 通知、メニューバーの青い点、タブの未読の数 | 対象にしない |
| 未読の印 | 灰色の輪で蓄積する。解除すると青に切り替え、カードは元の順位に戻る |
| Mentioned の行 | 誰からのものでも、Mute していても、青い点を付けて通知する。Mute による例外はない（owner の Notify、Skip draft pull requests、表の Notify には従う） |
| 配置 | 変更しない。Mute の対象の PR でも、レビューを依頼されれば `Todo` に追加する |
| Dismiss | 関係しない。Mute の対象の PR にも、Dismiss の復帰の契機を同じく適用する |

- カードが Mute の対象になるのは、その PR を Mute している、その PR のリポジトリを Mute している、その PR の作者を Mute している、のどれかに該当する間である。カードが Mute の対象なら、そのカードのすべての行（Mentioned を除く）が Mute の対象である。
- 利用者を Mute すると、その利用者が作成した PR の全体と、その利用者がほかの PR で起こした出来事の行が対象になる。後者は、その行だけを灰色にして通知しない。カードは対象にしない。行を起こした利用者は、行の actor（Approved は承認した人）で判定する。状態変化の行と Reaction の行（件数だけを検知し、誰が付けたかを取得しない）は、利用者の Mute の対象にしない。
- Mute と解除は、カードの右クリックのメニュー（`Mute this pull request`、`Mute owner/repo`、`Mute @alice`。解除は `Unmute …`）、行の右クリックのメニュー（`Mute @alice`）、設定画面の Muted の一覧（「設定画面 › Accounts」）、CLI で行う。
- 名前は GitHub に問い合わせずに保存し、大文字と小文字を区別せずに比較する。リポジトリは `owner/repo` の形で指定する。Bot は利用者として扱う。Bot のログイン名は GraphQL の `Bot.login` の表記（`renovate`。`[bot]` の接尾辞なし）で比較する（公開スキーマと実データで確認、2026-11-09）。
- Mute している間に記録した行は、解除すると、未読のものは青い未読の行になる。さかのぼって通知はしない。

Mute と Dismiss の違い：

| 操作 | 意味 | カード | 知らせる出来事 |
| --- | --- | --- | --- |
| Mute | 興味が薄い | 灰色で、区画の末尾に残る | Mentioned |
| Dismiss | 対応を終えた | 一覧から除き、Dismissed に移る | Mentioned、Reply in a thread I commented in、Review requested、Reopened（カードが復帰する） |

## カードの表示と監視

- カードが一覧から除かれるのは、利用者が Dismiss したときと、マージまたはクローズされた PR を日数の経過でアプリが Dismiss したときだけである（「Dismiss」）。これとは別に、disabled の owner の PR と、読めなくなった PR のカードは表示しない。既読と未読、更新からの日数、Draft かどうかは表示に関係しない。
- Merged／Closed：左の縦線とラベルが Merged／Closed になり、状況アイコンは表示しない。Review と Mine では、検知した時点で `Done` に移動する（利用者は `Done` の外へ移動できる）。`Done` にある間と配置なしの間は、n 日後に自動で Dismiss する（「Dismiss」）。
- disabled の owner の PR と読めなくなった PR（id で取得して、GitHub が NOT_FOUND のエラーを付けて `null` を返した PR）は、配置、Mute、Dismiss の状態を保ち、n 日と m 日の経過もそのまま数える。Dismiss していても `Dismissed` の一覧とその数に含めない。`place`、`dismiss`、`restore` は `not_found` である。owner を再び enabled にすると、配置と Dismiss の状態はそのまま有効になる。
- 読めなくなった PR は、未読の行があってもカードを表示せず、青い点を付けず、通知もしない。状態は保存し、再び読めるようになると元に戻る。戻ったときに青い未読の行があれば、Restore と同じ規則で青い点を付ける。検索結果に出なくなっただけではカードを変更しない。NOT_FOUND 以外のエラー（FORBIDDEN など）を付けて、またはエラーを付けずに `null` が返った PR は、読めなくなった PR にせず、1 件まで分割しても失敗した状況の取得と同じく扱う（カードを保ち、`status_fetch_failed` を付けて毎回再試行する。「取得の成功と失敗」）。
- カードの追加時刻（`Recently added` の並びの基準）は、カードが初めて表示された時刻で、Restore や復帰でも変更しない。

**監視**。Dismiss していないカードの PR は、マージやクローズのあとも、状況と出来事と Reaction を取得する。Dismiss している PR は、出来事の検知だけを行う（「Dismiss」）。Dismiss の記録だけが残る PR と、記録のない閉じた PR は、検索で再発見したときにだけ出来事を取得する。通知 API の通知は、reason に関係なく、取得している PR についてだけ再取得の合図になる（「API の使い分け」）。

## macOS 通知

通知するのは、owner の出来事の表で Notify がオンの種類の行である（既定は「行の種類と状態」の表のとおり。Added to merge queue と Merged / Closed の Notify の既定値はオフ）。Reaction は、1 回の取得で検知した同じコメントの分を 1 件にまとめる。通知の要否は行の生成時に決める（「通知の判定」）。owner の `Notify for <owner>` がオフならその owner のすべての行を通知しない。`Skip draft pull requests` がオンの owner では、Draft の PR の出来事を行にはするが通知しない。Mute の対象の行は、Mentioned を除いて通知しない。

- オン・オフは owner 単位（`Notify for <owner>`）。種類ごとのオン・オフは表の Notify の列である。
- 個別の通知の文面は、タイトルが「アカウント名 · 行の種類」（`bufferings-work · Mentioned`。種類は表の名前で、Merged / Closed の行は `Merged` と `Closed` に区別する）、サブタイトルが `owner/repo #番号` と PR のタイトル、本文が行の本文である。Reaction の本文は種類ごとの件数とコメント（`👍3 🎉1 “...”`）とする。
- 通知は owner ごとにまとめる。1 回の配信で、owner の個別の通知になるはずのものが 2 件以上なら 1 件のまとめ通知にし、1 件なら個別の通知にする。同じコメントの Reaction をまとめた通知は 1 件と数える。通常の取得、アプリの停止のあと、再接続のすべてに適用し、owner をまたいでまとめない。
- まとめ通知の文面は、タイトル `bufferings-work · 5 new events` とサブタイトル `example-org · in 3 PRs` である。N は行の数で、件数が 1 のときは `1 new event`、`in 1 PR` と単数形にする。
- アプリは、デーモンから受け取った通知を保持せずにすぐ表示し、macOS の既定の通知音を鳴らす。通知にボタンは付けない。
- 個別の通知を押すと、そのアカウントのポップオーバーを開き（常時表示ウインドウが開いていれば、ウインドウを前面に表示する）、その PR を配置しているタブ（配置なしなら All）を開いて、そのカードを選択する。検索の文字があれば消す。カードが `+ N more PRs` の中か、折りたたんだ区画の中にあれば、その区画を展開する。カードがもう表示されていなければ（Dismiss したあとなど）、タブを開くだけにする。押しただけでは行を既読にしない。
- まとめ通知を押すと、そのアカウントのポップオーバーを開く（タブは最後に表示したタブ）。

## キーボード

| キー | 動作 |
| --- | --- |
| ↑↓ | 選択を移動する |
| ⏎ | 開く（カードの見出しは PR、行はその出来事の場所。開くアイコンと同じ）。区画の見出しでは折りたたみの切り替え、`+ N more PRs` と `Show less` では展開と復帰、カードの中の `+ N more` では展開、`Older activity on GitHub` では PR のページを開く |
| ⇧R | 表示中のタブのすべての行を既読にする（「未読の消え方」） |
| ⌘F | 検索欄に移動する |
| ⌘C | 文字を選択していればその文字を、選択していなければ選択中のカードまたは行のリンク（`Copy link` と同じ）をコピーする |
| ⌫ | 選択中のカードを Dismiss する。Dismissed の一覧では Restore する |
| ⌥↑／⌥↓ | 選択中のカードを、区画の中で Mute の対象でないカードの間で 1 つ上／下に移動する（Review と Mine の `Done` 以外の区画。Mute の対象のカードでは何もしない） |
| D／T／W | 選択中のカードを Review の `Doing`／`Todo`／`Waiting` に移動する（Review タブだけ。`Done` のカードにも行える。位置は「Review」の規則） |
| ⌘1／⌘2／⌘3 | All／Review／Mine のタブを開く |
| Esc | Dismissed の一覧からタブに戻る |
| ⌘=、⌘−、⌘0 | 文字の大きさを変更する（「文字の大きさ」） |

カードの見出しと行のどちらを選んでいても、⌫、⌥↑／⌥↓、D／T／W はそのカードを対象にする。配置できない移動（`Done` のカードでの ⌥↑／⌥↓、Mine のカードへの D／T／W、All での ⌥↑／⌥↓、Mute の対象のカードでの ⌥↑／⌥↓）は何もしない。Mute の対象のカードのヒントには `⌥↑↓ Reorder` を表示しない。

**検索欄**。ポップオーバーを開いたときに検索欄にフォーカスは移らない。⌘F で検索欄に移る。検索欄で Esc を押すと、文字があれば文字を消して一覧に戻り、空なら一覧に戻るだけである（ポップオーバーは閉じない）。検索欄で ↓ を押しても一覧に戻る。検索欄にいる間、⇧R、D、T、W、⌫ は文字の入力と編集に使用する。検索の文字はタブごとに別に持ち、ポップオーバーを閉じたとき（常時表示ウインドウは閉じたとき）に消す。Dismissed の一覧は、タブとは別の検索の文字を持ち、一覧を閉じたときに消す（「Dismissed の一覧」）。

ポップオーバー下部のヒントは、選んでいるものに合わせて使用できるキーだけを、押した結果の表現で表示する。幅に収まらないときは 2 行に折り返す。⇧R と ⌘F は、タブではどの状態でも表示する。Dismissed の一覧には行がないので ⇧R を表示しない。

| 選択 | ヒント |
| --- | --- |
| カードの見出し（Review の `Done` 以外の区画） | `↑↓ Move  ⏎ Open  ⌥↑↓ Reorder  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search` |
| カードの見出し（Review の `Done`） | `↑↓ Move  ⏎ Open  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search` |
| カードの見出し（Mine の `Done` 以外） | `↑↓ Move  ⏎ Open  ⌥↑↓ Reorder  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search` |
| カードの見出し（All、Mine の `Done`） | `↑↓ Move  ⏎ Open  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search` |
| カードの見出し（Dismissed の一覧） | `↑↓ Move  ⏎ Open  ⌫ Restore  esc Back  ⌘F Search` |
| 行 | `↑↓ Move  ⏎ Open  ⇧R Mark all read  ⌘F Search` |
| 何も選択していない | `↑↓ Move  ⇧R Mark all read  ⌘F Search` |
| Dismissed の一覧で何も選択していない、または一覧が空 | `esc Back  ⌘F Search` |
| 区画の見出し | `↑↓ Move  ⏎ Collapse  ⇧R Mark all read  ⌘F Search`（折りたたみ中は `⏎ Expand`） |
| `+ N more PRs` | `↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search`（`Show less` では `⏎ Show less`） |
| カードの中の `+ N more` | `↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search` |
| `Older activity on GitHub` | `↑↓ Move  ⏎ Open  ⇧R Mark all read  ⌘F Search` |

**マウス**。クリックで選び、開くアイコンで開き、ダブルクリックで単語を、ドラッグで範囲を選択し、右クリックでその項目を選んでから（行なら既読にしてから）メニューを表示する（「押したときの動作」）。カードの見出しの右クリックのメニューは次の項目である。表示できない項目は表示しない。

| 項目 | 動作 |
| --- | --- |
| `Open on GitHub` | ⏎ と同じ |
| `Copy` | 選択している文字をコピーする（文字を選択しているときだけ） |
| `Copy link` | PR の URL をコピーする |
| `Move to Doing`、`Move to Todo`、`Move to Waiting`、`Move to Done` | Review のカードを移動する（今の区画を除く。`Done` のカードにも表示する） |
| `Move to Done`、`Move to Mine` | Mine の 1 本目の一覧のカードを Mine の `Done` へ、Mine の `Done` のカードを 1 本目の一覧の末尾へ移動する |
| `Remove from Review`、`Remove from Mine` | 配置なしにする（自分が作成した PR の Mine を除く。`Done` のカードにも表示する） |
| `Add to Review`、`Add to Mine` | 配置なしのカードを `Todo` の末尾、Mine の末尾に追加する。マージまたはクローズされた PR はそのタブの `Done` に配置する |
| `Mute this pull request`、`Mute owner/repo`、`Mute @alice` | Mute する（alice は作者。対象がすでに Mute なら `Unmute …`）。自分が作成した PR では `Mute @<自分の login>` を表示しない（自分を Mute している場合だけ `Unmute @<自分の login>` を表示する） |
| `Dismiss` | ⌫ と同じ |
| `Mark all as read` | ⇧R と同じ |

行の右クリックのメニューは `Open on GitHub`（その出来事の場所）、`Copy`、`Copy link`（その出来事の URL。出来事の URL がない行は PR の URL）、`Mute @alice`（alice は行の actor。alice をすでに Mute していれば `Unmute @alice`。actor がない行と自分の行では表示しない）、`Mark all as read` である。Dismissed の一覧のカードのメニューは `Open on GitHub`、`Copy`、`Copy link`、`Restore` である。

## 設定項目

タブは General／Accounts／Dismissed。設定はその場で反映し、保存ボタンや編集中の状態を持たない。

| タブ | 項目 | 既定 |
| --- | --- | --- |
| General | Launch at login | on |
| General | Appearance：System／Light／Dark（System は Mac の外観の設定に従う） | System |
| General | Text size：本文の文字の大きさ（pt）。数値と macOS 標準のステッパーで表示し、ステッパーは 1 ずつ変更する（「文字の大きさ」） | 12 |
| General | PR status interval | 1 min |
| General | Reactions interval | 3 min |
| Accounts | アカウントと owner の一覧と、選んだものの設定（「設定画面 › Accounts」） | — |
| Dismissed | Days before closed PRs are dismissed（n） | 3 |
| Dismissed | Days to keep dismissed PRs（m） | 7 |

General と Dismissed の各行の 1 行の説明は次のとおりである。Launch at login は "Runs in the menu bar after you log in to your Mac"（登録に失敗したときは "Allow shiibar-gh in System Settings › General › Login Items"）、Appearance は "System follows the appearance setting of your Mac"、PR status interval と Reactions interval は "Shorter means you notice sooner, but uses more API quota"、Text size は "Text in the popover and its window"、Days before closed PRs are dismissed は "Merged and closed PRs move to Dismissed after this many days"、Days to keep dismissed PRs は "Dismissed PRs can be restored for this many days"。数値の欄に整数以外を入力したときは "Enter a whole number" を表示する。Text size の欄は 9〜18 の外の値を受け付けず、範囲外の値を入力したときは "Enter a number from 9 to 18" を表示する。

値の範囲：Text size は 9 以上 18 以下の整数、PR status interval と Reactions interval は 1 分以上、Days before closed PRs are dismissed は 0 以上、Days to keep dismissed PRs は 1 以上。

**設定画面 › Accounts**。左にアカウントと owner の 2 段の一覧（アカウント名の前にアカウントの色の丸。owner はアカウントの下に字下げ）、下に `Add account…`。右は選んだものの設定である。アカウントが 1 つもないときは、右に「No accounts yet」と `Add account…` のボタンを表示する。

アカウントを選んだとき：

| 見出し | 行 | 右のコントロール |
| --- | --- | --- |
| Account | `Token`。説明はトークンの期限（`Expires 2027-02-01`。期限がなければ説明なし） | 状態の文字（問題と進行中のときだけ。「トークンの状態」）と `Edit…` |
| Account | `Menu bar icon color`。説明は "Tints this account's icon and the dot next to its name." | ポップアップ（色のサンプルと名前） |
| Owners | owner ごとに 1 行。名前と種類（Organization／Personal account／Public repositories） | ›（押すとその owner を選ぶ） |
| Owners | 末尾に右寄せの `Add owner…` | — |
| Muted | `Repositories`。説明 "Muted PRs stay in the list in gray. Only mentions notify." | 枠付きの一覧（`owner/repo`）、下に入力欄と `Add`、− |
| Muted | `Users`。説明 "Their PRs and their events. Bots are users too." | 同じ形の一覧 |
| Muted | `Pull requests`。説明 "Single pull requests you muted." | 同じ形の一覧（`owner/repo#number`） |
| Remove | `Remove this account`。説明は "Deletes this account and its owners from shiibar-gh: token, PRs, mutes and settings. Nothing changes on GitHub." | `Remove…`（確認のダイアログのあと削除する） |

Muted の一覧の入力欄は、`Add` を押すか Enter で確定する。空の値と、すでにある名前は追加しない（`Add` は押せない）。入力した文字は、デーモンが受け付けるまで欄に残し、受け付けたら消す。デーモンが拒否したときは文字を残し、その行の説明の下に、ほかの項目の失敗と同じ表示で `Couldn't mute: <理由>` を表示する（`−` による解除の失敗は `Couldn't unmute: <理由>`）。理由は「操作の反映」と同じくデーモンの `error`（接続できなければ `daemon not running`）で、`not_found` だけは読める文言にする：`pull request not found`（Pull requests の欄）、`repository not found`、`user not found`、解除では `not muted`。リポジトリの欄は `owner/repo` の形、Pull requests の欄は `owner/repo#number` の形でなければ追加しない。Pull requests の欄は、そのアカウントの知っている PR だけを追加できる（ワイヤの `mute`）。

owner を選んだとき：Owner／Notifications の 2 つのタブ（セグメント）。開いたときは Owner。

| タブ | 見出し | 行 |
| --- | --- | --- |
| Owner | Owner | `Enabled`（スイッチ。説明 "Off hides this owner's PRs and stops fetching."） |
| Owner | Remove | `Remove this owner`（説明 "Deletes this owner from shiibar-gh: its PRs and settings. Nothing changes on GitHub."。`Remove…`） |
| Notifications | Notifications | `Notify for example-org`（スイッチ。"Off keeps the table below but sends no notifications for this owner."）、`Skip draft pull requests`（スイッチ。"Events on draft PRs stay in the list but never notify."）。既定値はどちらもオン |
| Notifications | Events | 出来事の表（List／Notify のチェックボックス）と、最後の行 `Copy table from another owner`（説明 "Replaces the table above with that owner's."）`Copy…` |

Copy… のシート（題は `Copy table to example-org`）は、`Copy from` のポップアップで相手の owner を選ぶと、その owner の表を読み取り専用で表示し、Copy ボタンでその場で反映する。写すのは表だけで、スイッチは写さない。差分は表示しない。

**owner**。PR のリポジトリの owner がそのアカウントに登録済みなら、PR はその owner に属する。未登録の owner の公開リポジトリの PR は、そのアカウントの Public に属する。owner の表示名は owner のログイン名で、種類（Organization／Personal account）は追加時の問い合わせで決まる。owner を disabled にすると、その owner の PR のカードを表示せず、取得も通知もしない。Public がないときは、未登録の owner の PR を表示せず、取得もしない。owner の削除は、その owner の PR、行、配置、Dismiss の記録、出来事の表と設定をすべて削除する（再び追加しても戻らない）。アカウントの削除は、さらに Mute の一覧とトークン（Keychain）も削除する。owner の追加と削除は Keychain の項目を変更しない。

**Add owner… のシート**。owner のログイン名の欄と `Add`、`Add Public instead`（押すとその場で Public を追加して閉じる。Public がすでにあれば押せない）。Add で `owner lookup`（アカウントのトークンで `GET /users/{owner}` を引く）を実行し、見つかれば種類と数値の `id` を保存して閉じる。見つからなければ `Owner not found`、GitHub に接続できなければ `Couldn't reach GitHub` を欄の下に表示して閉じない。トークンの画面は続かない。

**Add account… と Edit… のシート**。同じ作りで、題は `Add account` と `Token for bufferings-work`。1. Create a token on GitHub（`Create token…` のボタンと、SSO の注記 "If an organization enforces SAML SSO, authorize the token for it after creating it (Configure SSO on the token page)."）。2. Paste the token and test it（貼り付ける欄と `Test`。欄の表示は常に点で、Edit… では保存済みを示す固定 12 個の • を表示する。アプリはトークン本体も文字数も知らない）。`Test` は保存せずに検証し、結果を一覧に表示する（「トークンの登録とテスト」）。結果の領域はシートを開いた時点で確保し（4 項目と owner の数の行）、結果が出るまでは項目名だけを薄く表示する。シートの高さは結果によって変更しない。OK でない項目があるときだけ、Save の行の左に `You can save now and test again later.` を表示する。Save は持ち主を確かめてから保存して閉じる（「トークン」）。Account の項目が ✗ のときは Save できない。Edit… では貼り替えたときだけ Save できる。途中でやめた場合、アカウントは作成しない。Save のあと、デーモンは保存したトークンで `token test` と同じ検証を行って `last_test` を更新し、その間は Token の行に `Checking…` を表示する（進行中を示す項目はワイヤに持たず、アプリは Save の応答から `last_test` が更新された `account_changed` までを進行中として扱い、300 秒を過ぎても更新がなければ進行中の表示をやめる）。問題があれば状態の列に理由を表示する（「トークンの状態」）。

**設定画面の規則**

1. 1 行＝左にラベルと 1 行の説明、右にコントロール 1 つ（状態の文字が付くことはある）。右の列は 240px 固定で右端に揃える。
2. コントロールは 6 種類：スイッチ、セグメント（2〜3 択で 1 行に収まるとき）、ポップアップ（4 択以上、または選択肢が長いとき）、数値とステッパー（Text size）、ボタン（押すものはすべてボタン。シート、ダイアログ、別のウインドウ、別のアプリが続くときは末尾に …）、状態の文字（問題と進行中だけ。正常なときは表示しない）。青い文字のリンクは使用しない。チェックボックスは表の中だけ。Test の結果はシートの中に表示する。
3. 行を押して先へ進むものは右端に ›。
4. 名前を打ち込むだけの一覧（Muted の Repositories、Users）は、枠付きの一覧と、その下の入力欄と `Add`、選んだ行を削除する −。自分の画面を持つもの（アカウント、owner）は一覧の末尾に `Add account…`／`Add owner…`。チップは使用しない。
5. Remove は末尾の独立した見出し。赤くしない。押すと確認を表示し、説明に「何が消えて、何が残り、GitHub 側は変更されない」を記述する。確認の題は `Remove <名前>?`、ボタンは `Remove` と `Cancel` である。
6. すべての枠に見出しを付ける。タブは場所、見出しは枠の内容。
7. owner の設定は 2 タブ、アカウントの設定はタブにしない。トークンの行は 1 行で、右のボタンは Edit… の 1 つ。
8. 押した直後に進行中の表示（状態の列に `Checking…`、ボタンは押せない）にし、結果が出たら差し替える。シートのボタンは押している間、`Test` は `Checking…`、`Save` は `Saving…`、`Add` は `Adding…` の表示になり、押せない。アプリは CLI を起動せず、デーモンに直接要求を送る。

## 実装方針

**構成**。デーモン、CLI、アプリの 3 つに分割する。

- デーモン（Rust）：GitHub の取得、状態（未読、配置と順位、Dismiss、Mute、カードの追加時刻、設定、アカウント、owner）の保持と保存、トークン（Keychain の読み書きはデーモンだけ）。Unix ソケットで NDJSON を話し、状態の変化を接続中のクライアントに push する。
- CLI（Rust）：ソケット経由でデーモンを叩くだけのクライアント。
- アプリ（Swift）：UI（メニューバー、ポップオーバー、設定画面）と macOS 通知。作者のアバターの画像は、デーモンが渡す URL からアプリが読み込む。CLI と同じソケットでデーモンと話す。デーモンの起動・停止・更新時の差し替えはアプリが行う（launchd は使用しない）。

**配布と署名**。リリース版は GitHub Actions で Developer ID Application の証明書で署名し（hardened runtime）、Apple の公証を受けて GitHub Releases で公開する。利用者は Homebrew の cask（`bufferings/tap`）でインストールする。デーモンと CLI は `.app` の中に同梱し、cask が CLI のリンクを作成する。開発版は、ローカルで作成した固定の署名の ID で署名して `~/Applications` に配置する。アプリは `Shiibar GH.app`、bundle identifier は `shiibar.gh`、同梱するデーモンと CLI の署名の識別子は `shiibar.gh.daemon` と `shiibar.gh.cli` で、変更しない（Keychain と通知の許可が識別子に結び付くため）。対応する macOS は 14 以上で、Apple Silicon だけを対象とする。Keychain の項目の許可は、保存したプログラムの designated requirement（DR）に結び付く。Developer ID の DR は Team ID と識別子で決まり、版を更新しても満たされるので、更新で許可のダイアログを表示しない。ad hoc の署名の DR は、その版のコードに結び付く（Apple TN3127 で確認。2026-11-05）。開発版とリリース版を切り替えたときは、DR が異なるので 1 回ダイアログを表示する。

**UI**。SwiftUI（足りない部分は AppKit）。メニューバーのアイコンは NSStatusItem、ポップオーバーは NSPopover、常時表示は NSPanel。ログイン時起動は SMAppService。外観は設定の Appearance に従い、System なら macOS のライトとダークの設定に従う。ボードはライトだけなので、ダークの色は実装で決め、所有者が実機で確認する。メニューバーのアイコンの画像は、外観（ライトとダーク）、アカウントの色、青い点、三角が前回と同じなら再設定しない（画像の設定が再描画と外観の通知を起こし、繰り返しになるのを防ぐため。0.3.0 で CPU を使用し続けた原因）。この修正の合格の基準は、操作をしないまま 1 時間が経過したとき、アプリの CPU 時間が経過時間の 1% 未満であることである。

**Launch at login の同期**。設定の値（`launch_at_login`）と macOS のログイン項目の登録は、後から変更したほうに合わせる。CLI などで設定を変更すると、デーモンはアプリに設定の変更を知らせ、アプリはログイン項目を登録または解除する。システム設定でログイン項目を変更した場合は、アプリが次に起動したとき、または設定画面を開いたときに、その状態を設定に反映する。

**トークン**。アカウントごとに classic PAT 1 つ。スコープは `repo`、`notifications`、`read:org`。通知、PR の検索と詳細、チェック、チームの所属、Public の取得をすべてこのトークンで行う。owner と Public はトークンを持たない。アプリは GitHub に書き込まないので、`repo` が書き込みを許すことは受け入れる。classic にそろえる理由は、通知 API が classic PAT でしか使用できないためである（fine-grained PAT の権限の一覧に通知のエンドポイントがない。docs.github.com の「Permissions required for fine-grained personal access tokens」で確認、2026-11-08）。

- アカウントの識別子は GitHub のユーザーの数値の id（GraphQL の `viewer { databaseId login }`。REST の `GET /user` の `id` と同じ値）で、表示名は login である。node id は形式の移行中で同じ人の id が変更されうるため（docs.github.com「Migrating GraphQL global node IDs」、2026-11-09 に確認）、識別子には使用しない。`databaseId` は公開スキーマで `Int`、非推奨の印なし（2026-11-09 に確認）。GitHub 側で login を変更すると、次の取得で表示、Keychain の項目の login、CLI の `<account>` も新しい login に追従する。
- 保存の手順。`token set`（トークンは標準入力）は、保存の前に `viewer { databaseId }` で持ち主を確かめる。アカウントと同じ id なら保存する。違えば `Belongs to octocat`（octocat はそのトークンの login）を返して保存しない。GitHub に接続できなければ `Couldn't reach GitHub` を返して保存しない。`account add`（トークンは標準入力）は、`viewer` で id と login を取得してアカウントを作成し、保存する。接続できなければ何もしない。同じ id のアカウントがあれば `bufferings-work is already added` を返す。
- 取得は保存済みのトークンをそのまま使用し、デーモンが持ち主を再確認することはない（classic PAT の持ち主は変更されない）。アカウントの付け替えはなく、Remove してから Add account… する。
- トークンの期限の 7 日前からそのアカウントに警告を付ける。期限のないトークンは警告しない。期限を過ぎたトークンは、無効なトークン（401）として扱う。
- トークンが 401 を返すか期限を過ぎると、そのアカウントのすべての取得を止めて警告する。トークンを差し替えると、次の定期取得で自動で再開する。
- トークンのないアカウント（`token reset` のあと）は取得せず、`no_token` の警告を付ける。トークンを登録すると、次の定期取得で再開する。このアカウントでの `public` 以外の `owner_add` と `owner_lookup` は `invalid`（`Account has no token`）で拒否する。認証なしで GitHub に問い合わせることはない。
- 応答に `X-GitHub-SSO` が付いたら、SSO の承認が必要という警告を付けるかを判定する。ヘッダーは organization の数値の id を返す（`X-GitHub-SSO: partial-results; organizations=21955855,20582480`。docs.github.com/en/rest/authentication/authenticating-to-the-rest-api で確認、2026-11-05）ので、そのアカウントの登録済み owner の数値の id（`owner lookup` で保存した `github_id`）と比較し、一致した owner ごとに `SSO authorization required for example-org` の警告を付ける。一致しない organization は無視し、警告を付けない。1 つの organization への 403 では、ヘッダーは承認の URL だけを返し、organization の id を返さない（同じページで確認、2026-11-10）。この形は、organization または user の owner の要求（検索と、owner ごとの状況の取得の `Status`、`Compare`、`Contexts`）で受けたときはその owner の `sso_required` の警告とし、警告の `url` はヘッダーの URL にする。このときは失敗に数えず（「取得の成功と失敗」）、その owner のその回の残りの取得は行わない。Public の要求（検索と状況の取得。どの organization の承認かが分からない）と、複数の owner にまたがる要求（通知、チームの所属）で受けたときは、その要求の失敗として扱い、再試行と 5 分の帯の対象にする。502 または 504 で分割した Public の検索の一部だけがこの形で拒否されたときは、拒否された部分だけを失敗にし、応答した部分の結果は使用する。URL だけの形は 403 の応答でだけ評価し、200 の応答では `organizations=` の形だけを評価する。チームの所属の取得（`/user/teams`）の 403 に SSO のヘッダーが付いたときも、複数の owner にまたがる要求として失敗にする（`scope_missing` にはしない）。owner を示さない `sso_required` の警告は付けない。`organizations=` の形で付けた警告の `url` は `null` で、ほかの organization の URL を付けない。帯の `Authorize…` はヘッダーの URL（なければ GitHub のトークンの設定ページ）を開く。ほかの owner の取得は続くので三角は付けない。承認後は次の取得でヘッダーが消え、警告も消える。失敗した要求だけを再実行する取得（「取得の成功と失敗」）は、要求を再実行した owner の警告だけを更新し、再実行しなかった owner の警告と、ほかの応答で受けた `organizations=` の形の警告を消さない（消すのは、すべての要求を行う取得である）。
- Create token… は `https://github.com/settings/tokens/new?scopes=repo,notifications,read:org&description=shiibar-gh` をブラウザで開く。期限は指定せず、GitHub の既定に従う。

**トークンの状態**。設定画面の Token の行の右には、次のうち最も上のものを 1 つ表示する：`Checking…`（進行中）、`Keychain unavailable`（「Keychain を読めないとき」。Edit… を表示しない）、`No token`（灰、`no_token`。Edit… は空の欄で開く）、`Invalid`（赤、`token_invalid`）、`Expires in N days`（黄、`token_expiring`。1 日未満は切り上げて `Expires in 1 day`）、`Missing scope`（黄、`scope_missing`）、`SSO authorization required`（黄、`sso_required`）。正常なときは何も表示しない。

**Keychain を読めないとき**。デーモンは起動直後の最初の取得で Keychain を読み込み、成功したトークンを保持する。読み込むのは DB にアカウントが 1 件以上あるとき、または `reset` の直後だけで、アカウントのない DB で起動したときは Keychain に触れない。項目がなく DB にアカウントがあるときは、すべてのアカウントを `no_token` にし、`keychain` は `ok` とする。読み込めなければ、前回の内容を表示したまますべてのアカウントの取得を止め、自動では再読み込みしない。2 種類に区別する。OS のエラー（許可の拒否など）は `keychain_unavailable`、項目はあるが内容を読み取れないときは `tokens_unreadable` である。

- アプリは起動直後にダイアログで知らせる。`keychain_unavailable` は題 `Couldn't read tokens from Keychain`、説明 "If macOS asked whether shiibar-gh may use the Keychain, allow it, then retry."、ボタン `Retry`（既定）と `Not now`。Retry と Reset が失敗したときは同じダイアログをもう一度表示する。`tokens_unreadable` は題 `Saved tokens are unreadable`、説明 "Reset deletes the Keychain item. You enter every token again. PRs and settings stay."、ボタン `Reset tokens`（既定）と `Not now`。
- Not now で閉じると、すべてのアカウントのアイコンに三角、ポップオーバーと設定画面の Accounts の上端に帯（文面と `Retry…`／`Reset tokens…`）が残る。帯のボタンは同じダイアログを表示する。Retry して失敗したら同じダイアログをもう一度表示する。
- 読めない間はトークンに触れる操作を止める。Token の行は Edit… を表示せず状態 `Keychain unavailable` だけ、`Add account…`、アカウントの `Remove…`、Add owner… のシートの `Add`（GitHub への問い合わせにトークンが必要になる）は押せない。`Add Public instead`、owner の削除、Enabled は使用できる。
- CLI では Retry は `refresh`、Reset は `token reset` である。`token reset` は Keychain の項目を削除し、すべてのアカウントをトークンなし（`no_token`）にする。アカウント、owner、PR、行、設定は残る。
- DB を読めないときは従来どおり帯だけで、ダイアログは表示しない。

**API の使い分け**

| 必要なもの | 取り方 |
| --- | --- |
| 取得の開始（login の追従） | アカウントの取得（Reaction だけの取得を除く）は、最初に GraphQL の `viewer { databaseId login }`（ログの名前は `Viewer`）を要求し、その login に表示を追従させる（「トークン」）。この要求が失敗すると、その回の取得をそこで終え、アカウントの取得の失敗として扱う（通常の待ち時間で再試行し、5 分の帯の対象。401 と上限は「取得の成功と失敗」の各規則）。失敗した要求だけを再実行する取得でも最初に要求する |
| どの PR が更新されたか | アカウントごとに REST Notifications API（all=true。If-Modified-Since と X-Poll-Interval に従う）。通知は、取得している PR（Dismiss しているカードを含む）の再取得の合図としてだけ使用し、知らない PR と、Dismiss の記録だけが残る PR を取り込まない。reason で行の種類を決めない |
| Review requested、Mentioned、Comment、Merged／Closed、Reopened、Added to／Removed from merge queue | 更新された PR の GraphQL timelineItems(since:)（ログの名前は `Events`）。nodes(ids:) でまとめて取る。行の種類は下の判定の表に従う。`RemovedFromMergeQueueEvent` は `actor`、`enqueuer`、`reason`、`createdAt` を取得する。理由が `merged` 以外の取り除きがあれば、その PR だけの要求（ログの名前は `MergeQueue`。`isRequired` に PR の番号を変数で渡すので、複数の PR をまとめる `Events` では取得できない）で、マージキューの追加と取り除きの出来事と `beforeCommit` を取得し、`beforeCommit` の `statusCheckRollup.contexts` から、CheckRun の `name`、`conclusion`、`detailsUrl`、`isRequired(pullRequestNumber:)` と、StatusContext の `context`、`state`、`targetUrl`、`isRequired(pullRequestNumber:)` を取得する（公開スキーマの照会と bevyengine/bevy の実データで確認、2026-11-13） |
| Reply | Reply の対象のスレッドの id を記録し、id でスレッドのコメントを取得する |
| 状況アイコン、状態ラベル、assignees、作成時刻、更新時刻 | GraphQL：reviewDecision、statusCheckRollup、mergeable、mergeStateStatus、isDraft、compare.behindBy、headRefOid、assignees、createdAt（`PullRequest.createdAt: DateTime!`。公開スキーマで確認、2026-11-10）、updatedAt。nodes(ids:) で 50 件ずつ。Dismiss していないカードの PR だけが対象で、`updatedAt` が進んだ PR の出来事を取得する |
| 失敗したチェックの名前 | REST の GitHub Actions（head_sha で絞った workflow run と、その job）の job 名、次に Commit status の名前。statusCheckRollup に含まれない run（Copilot のレビューなど、event が dynamic の run）は除く |
| 自分のコメントへの Reaction | Dismiss していないカードの PR ごとに、自分のコメント、レビュー、レビューコメント、PR の本文の id を集め、GraphQL の nodes(ids:) で reactionGroups を定期取得し、件数の増加を検知する |
| 対象 PR の発見 | 検索だけで行う（通知からは発見しない）。アカウントのトークンで、owner ごとに GraphQL search を 6 つ：開いている PR の `is:pr is:open involves:@me updated:>=D`、`is:pr is:open reviewed-by:@me updated:>=D`、`is:pr is:open author:@me`、`is:pr is:open review-requested:@me`（Review requested to my team の List がオフなら `is:pr is:open user-review-requested:@me`）と、閉じた PR の `is:pr is:closed involves:@me updated:>=T`、`is:pr is:closed reviewed-by:@me updated:>=T`。D は発見の範囲（「定数」）の日数前の日付、T はその owner の出来事の取得の範囲の始まり（「監視開始より前の出来事」）の時刻（`updated:>=2026-11-12T14:30:00Z` の形。`gh api` の REST と GraphQL の検索で、時刻の指定が秒の単位で検索の条件になることを確認、2026-11-12）である。owner は種類に合わせて `org:` または `user:` を加え、Public は `is:public` を加え、結果からそのアカウントの登録済みの owner の PR を除く（検索の文字列には除外を加えない。0.1 と同じ） |
| チームの所属 | アカウントごとに REST `GET /user/teams`（`read:org`。0.1 が Public のチームの所属に使用していた API）で、所属するすべてのチームの `id` と `slug` を取得する。owner ごとの問い合わせはしない |
| owner の種類と id | `GET /users/{owner}` の `type`（`Organization` または `User`）と `id` |
| トークンの持ち主と期限 | GraphQL の `viewer { databaseId login }` と、応答ヘッダー `github-authentication-token-expiration` |

検索で発見した PR の扱いは次のとおりである。

- 検索の結果は、各 PR の `updatedAt` と状態（開いているか）を含む。
- 取得している PR（Dismiss しているカードを含む）は、`updatedAt` が進んでいれば出来事を取得する。Dismiss しているカードでは、復帰の契機の 4 つの行だけを生成する（「Dismiss」）。
- Dismiss の記録だけが残る PR は、記録した `updatedAt` より進んでいれば出来事を取得し、復帰の契機の行を生成した場合だけ、新しく発見した PR として表示する。
- Dismiss しているカードと、Dismiss の記録だけが残る PR で、出来事を取得して復帰の契機がなかったときは、保存している `updatedAt` を検索の結果の値に進める。そのため、次に更新されるまで同じ PR の出来事を再取得しない。閉じていると分かった記録だけの PR は、記録を削除する（「Dismiss の記録」）。
- 知らない開いている PR は、新しく発見した PR として取り込み、表示する。
- 知らない閉じた PR は、出来事を取得し、復帰の契機の行を生成した場合だけ、新しく発見した PR として表示する。生成しなければ取り込まない。取り込んだときに生成する行は、復帰の契機の 4 つの行（Mentioned、Reply in a thread I commented in、Review requested、Reopened）だけである。出来事の取得に失敗したときは、その PR と owner を取り直しの対象として記録し、以降の取得でその owner の取得のたびに、状況と、失敗した時点の取得の範囲からの出来事を取り直す（owner の取得の範囲が進んで検索に出なくなっても出来事を失わない）。GitHub が見つからないと返した場合と、owner を削除した場合は、記録を消す。
- PR の更新時刻（`updated_at`）は、閉じた PR でも会話欄のコメントとレビューで進む（rust-lang/rust の閉じた PR で、最後のコメントまたはレビューの時刻と `updated_at` の一致を `gh api search/issues` で確認、2026-11-12。#165844、#165805、#165820、#163225）。アサインでも進む（rust-lang/rust の #165870 と #165869 で、`assigned` の出来事の時刻と `updated_at` の一致を `gh api` で確認、2026-11-13）。そのため、発見の範囲より古い PR に新しくアサインされた場合も、`involves:@me updated:>=D` の検索で発見する。ブランチの削除とラベルの変更でも進むので、カードを表示または復帰させる契機は、更新時刻ではなく行の生成にする。

**レート制限**。上限は GitHub のもの（アカウントごと。REST API は 1 時間に 5,000 リクエスト、GraphQL API は 1 時間にポイントで数える別の上限。docs.github.com の「Rate limits for the REST API」で確認、2026-11-09）をそのまま使用し、アプリ側の上限は設けない。GraphQL の応答の `rateLimit`（`limit`、`remaining`、`resetAt`）と REST の応答ヘッダー（`x-ratelimit-limit`、`x-ratelimit-remaining`、`x-ratelimit-reset`）を毎回記録する。使用率がどちらかの API で 80% 以上になると警告する（`graphql_near_limit`、`rest_near_limit`）。取得の間隔は設定の値のまま変更しない。残量が尽きたときは、そのアカウントの通知を含むすべての取得を止め、再開の時刻を付けたエラーを表示する。再開後は通知 API の since で停止中の通知を取得するので、失うのは停止中に起きて元に戻った状態の変化と、出来事の検知時刻だけである。停止中は `refresh` も取得しない。二次レート制限も同じ扱いで、指定の時間（retry-after、x-ratelimit-reset、指定がなければ 1 分）だけそのアカウントのすべての取得を止め、再開の時刻を表示し、自動で再開する。

使用量はポップオーバーの見出しの 2 行目に、`Updated … ago` に続けて、細いバーとポイント（`1,240 / 5,000`）で表示する。値は GraphQL と REST のうち使用率（使用量＝`limit` − `remaining` を上限で割った値）の高い方で、バーの長さは使用率、数字は使用量と上限である。マウスを乗せると `GraphQL API 1,240 / 5,000 · REST API 100 / 5,000` の形で両方の使用量と上限を表示する（GraphQL はポイント、REST はリクエストで、単位の表記はしない）。80% 以上はバーと数字を警告の色にする。値がまだないときはバーを表示せず `API –` とする。表示の詳細は設計図に従う。設定画面には使用量を表示しない。

**取得の成功と失敗**。取得は、要求（GitHub への 1 回の HTTP の問い合わせ）を単位に成否を扱う。要求の種類は、取得の開始（`Viewer`）、owner の検索、状況、出来事、通知、チームの所属、失敗したチェックの名前、Reaction である。

- id で複数の項目をまとめる GraphQL の要求は、ログの名前で `Status`（状況）、`Compare`（base との差）、`Contexts`（チェックの名前）、`Reactions`（Reaction）が 1 つの要求で 50 件まで、`Events`（出来事）が 5 件までである。owner の検索（`Search`）は 1 つの要求に複数の検索を並べる。502 と 504 の応答を受けた要求は、その要求だけを、件数（id の数、並べた検索の数）を半分にした 2 つの要求に分割してすぐ再試行する。分割した要求がまた 502 または 504 なら、1 件になるまで同じく分割する。1 件の要求の失敗は、その要求の失敗である。
- 成功した要求の結果は、ほかの要求の成否を待たずに反映する。
- 失敗した要求は記録し、次の取得（下の待ち時間のあと）では、失敗した要求だけを再実行する。前回の通常の取得の開始から設定の間隔がたった時点では、通常の取得（すべての要求）を行う。

owner の取得の成功は、その owner の `Search`、`Status`、`Compare`、`Contexts` の要求がすべてエラーなく終わったことを指す。状況の取得は owner ごとの要求である。1 件まで分割しても 502 または 504 で失敗した `Status`、`Compare`、`Contexts` の要求は、owner の失敗にせず、その PR に警告（`status_fetch_failed`）を付けて、次の取得から毎回再試行する。まだ知らない PR（検索で初めて検出し、状況を一度も取得できていない PR）では、カードも警告も表示せず、次の取得から毎回再試行するだけである（警告の文に必要な owner/repo #番号を、検索の結果から取得できないため）。`Events`、`Reactions`、失敗したチェックの名前（REST）の要求は PR ごとの扱いで、owner の失敗にしない（出来事の失敗は下の取り直しの時刻と `events_fetch_failed`）。owner の成功の時刻は、その取得を開始した時刻である（結果を反映した時刻ではない。再実行で成功した場合は、最初の取得を開始した時刻）。この時刻を、出来事を取得する範囲（「監視開始より前の出来事」）の始まりに使用する。アカウントの取得の成功は、そのアカウントのすべての owner の取得と通知の確認がエラーなく終わったことを指す。1 つでも失敗した要求が残っている間は、アカウントの取得は失敗である。ここでの失敗した要求は、取得の開始（`Viewer`）、owner の成功を決める要求（`Search`、`Status`、`Compare`、`Contexts`。1 件まで分割しても 502 または 504 で失敗した `Status`、`Compare`、`Contexts` を除く）、通知、チームの所属の要求だけである。PR ごとの要求（1 件まで分割しても失敗した `Status`、`Compare`、`Contexts`、`Events` とそれに続く要求（`MergeQueue` など）、`Reactions`、失敗したチェックの名前の REST）の失敗は、アカウントの取得を失敗にしない。Updated … ago は、そのアカウントの取得が最後に成功して終わった時刻である（成功したことがなければ `Not updated yet`）。失敗が続く間は時刻が進まないので、帯が出る前でも古いデータだと分かる。PR も出来事もなかった場合も、成功なら更新する。上限、401、トークンなし、Keychain を読めない状態で取得を止めている間は進まない。

アカウントの定期取得（全 owner の検索と状況の取得、および通知の確認）は 1 回の取得として扱い、その終了時刻から次の取得の時刻を 1 つ決める。成功なら設定の間隔のあととする。失敗なら 5、10、20、40 秒と延ばし、40 秒のあとは 40 秒を繰り返す。どの待ち時間も設定の間隔を超えない。通知の確認は、前回の確認から X-Poll-Interval の秒数がたっていなければその回は省き、省いた回も成功として扱う（「通知 API の取り方」）。Reaction の取得は別の時刻（Reactions interval）で行い、アカウントの取得の成功と失敗の判定にも Updated にも関係しない。

`refresh` はいつでもすぐに取得し、通常の 1 回の取得（すべての要求）として扱う。成功すれば失敗の回数を 0 に戻し、Updated を進め、次の定期取得をその終了時刻から設定の間隔のあとにする。失敗すれば失敗の回数を 1 つ進め、最初の失敗なら 5 分の起点になる。

- 出来事の取得に失敗した PR は、失敗した時点の取得の範囲の始まりを、その PR の取り直しの時刻として記録する。次の取得ではその時刻から取り直し、成功すれば記録を消す。そのため、owner の成功の時刻が進んでも出来事を失わない。検索で発見した知らない閉じた PR（「API の使い分け」）も同じく、owner とともに記録して取り直す。
- 通知 API の since と Last-Modified は常に進める。通知を合図にした取得に失敗した PR も、同じく取り直しの対象にする。知らない PR（repo#number → id の対応がない PR）の通知と、取得できる owner に属さない PR（disabled の owner、どの owner にも属さない PR）の通知は無視し、ほかの取得を妨げない。
- 出来事の取得に続けて失敗する PR には、その PR を示す警告を付け、取得のたびに取り直す。
- スコープ不足で取得できなかった部分は失敗に数えず、取得できる部分の取得を続けて警告する（`scope_missing`）。owner に結び付けられる SSO の未承認（`sso_required`）も同じく失敗に数えず、警告にする。その取得は成功として扱い、Updated は進む。ただし `sso_required` で止めた owner は、その owner の取得の成功ではないので、その owner の成功の時刻は進まない。承認のあとの取得では、前回の成功の時刻を基に出来事を取得する。
- ネットワークの失敗、5xx、タイムアウト、本文が空の 200 の応答（GraphQL の応答を解釈できないもの）は失敗で、上の待ち時間で再試行する。
- 取得の失敗の帯と三角（`fetch_failed`）は、最初の失敗から 5 分たっても成功していないときに表示し、成功で消す。それまでの失敗は、`Updated … ago` の時刻が進まないことだけで示す。最初の失敗の時刻は保存せず、デーモンの再起動で消える。上限による停止、401、トークンなし、Keychain を読めない状態の間は取得していないので、`fetch_failed` を付けない（それぞれの警告を表示する）。これらの停止を始めた時点で失敗の回数と最初の失敗の時刻は消え、再開後の最初の失敗から再び数える。
- 401 は失敗で、トークンを差し替えるまでそのアカウントの取得を止める。
- 上限による停止は失敗である。停止中は上の待ち時間ではなく、再開の時刻まで取得しない（「レート制限」）。
- 失敗はアカウントごとに扱い、ほかのアカウントの取得を止めない。1 つの owner の失敗は、同じアカウントのほかの owner の取得を止めない。
- `refresh` は再試行の時刻を待たずにすぐに取得する。401 で止めたアカウントも 1 回だけ取得し、401 が続けば止めたままにする。Keychain を読めない状態では、まず Keychain を再読み込みする。

**ログ**。デーモンのログのすべての行は、先頭に時差付きのローカル時刻（`2027-01-15 08:00:00+09:00`）を付ける。失敗した要求ごとに、`request of <login> failed after <ms> ms: <要求> (<件数>): <エラー>` の 1 行を info で記録する。`<要求>` は GraphQL ではクエリの名前（`GraphQL Status`）、REST では `GET <path>` である。`<件数>` は GraphQL では、変数 `ids` に id の配列を渡す要求（`Status`、`Contexts`、`Reactions`、`Events`）では id の数（`ids: 50`）、それ以外の要求では変数の数（`variables: 6`）で、REST では省く。変数の数は項目の数と一致しないことがある。`Search` は検索 1 つにつき 1 つ、`Compare` は PR 1 件につき 2 つ（PR の id と head のコミット）の変数を使用するので、50 件の `Compare` は `variables: 100` になる。`<エラー>` は、GitHub が返した状態コードと、あれば `x-github-request-id` を含む（5xx は `network: GitHub answered 502 (request id …)`、4xx は `forbidden: … (GitHub answered 403, request id …)` の形）。502 と 504 で分割して再試行した要求も、失敗のたびに記録する。REST の 404 は debug で記録する。アカウントの取得が失敗した回は、その回の終わりに `fetch of <login> failed: <エラー>`（`<エラー>` はその回の最初の失敗）の 1 行も記録する。失敗した要求の数に関係なく、1 回の取得につき 1 行である。

**状態の保存**。行の未読、配置（タブ、区画、順位、クローズ前の区画）、Dismiss（時刻と、自動の Dismiss をしない印）、Dismiss の記録、Mute（PR、リポジトリ、利用者）、カードの追加時刻、監視開始時刻、owner ごとの最後に取得に成功した時刻、アカウントごとの最後に取得に成功して終わった時刻、失敗した要求の記録、PR の前回の値（Checks の前回の確定した結果と、そのときの head のコミットを含む）、PR の作成時刻と自分の最新のレビューの時刻と自分または自分のチームへの最新の依頼の時刻、Reaction の基準値、設定（`text_size` を含む）、アカウント、owner、出来事の表はデーモンが SQLite に保存する（SQLite はデーモンに組み込み、macOS の libsqlite3 は利用しない）。最後に表示したタブ（ポップオーバーとウインドウで別々）、Group by、Then by、並び、グループの順番、折りたたみ、`+ N more PRs` の展開、ウインドウの位置と大きさ、`Keep on top` は画面の状態なので、アプリがアカウントごとに UserDefaults に保存する。検索の文字、文字の選択、Dismissed の一覧を開いているかは保存しない。GitHub 側には何も書き込まない。トークンは DB に保存せず Keychain に保存する。すべてのアカウントのトークンは Keychain の 1 つの項目にまとめて保存し、項目にはアカウントの id と login も記録する。開発版は再インストールのたびに Keychain の許可のダイアログを表示するので（ローカルの署名の ID には Team ID がなく、項目の許可がビルドごとの cdhash に結び付くため）、項目を 1 つにしてダイアログを 1 回に抑える。トークンの追加、置き換え、削除は、この項目を読み、変更して保存する。

**0.3 と 0.2 からの更新**。0.3 の DB（スキーマの版 5）と 0.2 の DB（版 4）は、起動時に版 6 に移行する。引き継ぐのはアカウント（id、login、色、登録の順）だけで、owner の一覧、出来事の表、Exclusions、設定（外観、文字の大きさ、間隔など）、PR、行、未読と既読、Snooze、通知の配信の記録、通知 API の since は引き継がない。移行は 1 つのトランザクションで行い、アカウント以外の表を削除して版 6 の表を作成し、`user_version` を 6 にする。失敗したらロールバックし、元の版のまま「DB を読めないとき」の状態にする。Keychain の項目は版 2 のまま変更しない。アプリは 0.3 以前の画面の状態（UserDefaults）を読み込まない。更新後は、利用者が owner を再登録する。リリースノートに明記する。`launch_at_login` は初期値になるが、アプリは起動時にログイン項目の登録の状態を設定に反映する（「Launch at login の同期」）。

取得の最初の失敗の時刻（「取得の成功と失敗」）は保存しない。

0.1 のデータは引き継がない。0.1 のスキーマの DB は「DB を読めないとき」と同じ扱いにし、Reset で退避する。0.1 の Keychain の項目は読み込まず、0.2 以降は別の名前の項目を使用する。トークンは利用者が再登録する。

**DB を読めないとき**。デーモンは起動するが、GitHub の取得をせず、DB に変更を加えない。アイコンに三角を表示し、ポップオーバーに「Couldn't read saved state」と Reset ボタンだけを表示する。Reset を押すと、DB ファイルを別名で退避し（退避したファイルは削除しない）、空の状態で通常の動作を始める。CLI は `shiibar-gh reset` で同じ操作を行い、ほかのコマンドはエラーになる。DB を読めるときの `reset` はエラーにして、何も変更しない。アカウントは Keychain の項目（id、login、トークン）から復元し、owner は復元しない。

**classic PAT のスコープ**

| スコープ | 用途 |
| --- | --- |
| `repo` | PR、レビュー、コメント、reviewDecision、statusCheckRollup、compare（behindBy）、mergeable、GitHub Actions の job、Commit status、マージキュー。非公開リポジトリを含む |
| `notifications` | Notifications API |
| `read:org` | チームの所属（チーム宛てのレビュー依頼とチームへのメンションの判定）、organization の非公開のチームの参照 |

失敗したチェックの名前は、0.1 と同じく GitHub Actions の job から求める。`repo` で statusCheckRollup の個々の CheckRun を直接取得できる場合は、その方法に差し替えてよい（「未決」）。

**reason を判定に使用しない理由**。reason は「なぜ自分に通知されるか」を表すスレッド単位の値で、起きた出来事を表さない。一度 mention になったスレッドは、その後メンションされなくても mention のままになる。

**PR の識別**。鍵は GraphQL の node id と、それを取得したアカウントの組である。同じ PR を 2 つのアカウントで取得した場合は別の PR として扱い、配置、Dismiss、Mute、未読を共有しない。PR は検索で発見したときに取り込む。repo#number → id の対応は、保存した PR（prs 表の owner、repo、number）から求める。通知 API は repo と number しか持たないので、通知の PR はこの対応で id に変換し、取得している PR の再取得の合図にする。対応のない PR（知らない PR と、Dismiss の記録だけが残る PR）は通知からは取り込まない。

**行の種類の判定**

| 行 | 判定 |
| --- | --- |
| Review requested | REVIEW_REQUESTED_EVENT の requestedReviewer が自分 |
| Review requested to my team | REVIEW_REQUESTED_EVENT の requestedReviewer が自分が属するチーム |
| Mentioned | 自分以外が投稿したコメント、レビューの本文、レビューコメント、PR の本文の bodyHTML に、自分への user-mention のリンクがある |
| My team mentioned | 同じく、自分が属するチームへの team-mention のリンクがある（自分への user-mention もあれば Mentioned だけにする） |
| Comment on my PR | 自分の PR の ISSUE_COMMENT、レビューの本文、インラインコメントで、author が自分でない |
| Comment on other PRs | 自分が作成していない PR の ISSUE_COMMENT で、author が自分でない |
| Approved | 自分の PR の PULL_REQUEST_REVIEW で、state が APPROVED、author が自分でない |
| Changes requested、Checks failed、Checks passed、Conflicts、Mergeable | タイムラインではなく、状況の取得で検知した値の変化（「状態変化の行」） |
| Reply in a thread I commented in | 自分がコメントしたスレッドの、自分以外のコメント |
| Reply in a thread I was mentioned in | 自分または自分のチームがメンションされたスレッドの、メンションより後の自分以外のコメント |
| Merged／Closed | MERGED_EVENT／CLOSED_EVENT（自分の操作かは問わない。MERGED_EVENT と対になる CLOSED_EVENT は除く。「Merged、Closed、Reopened の行」） |
| Reopened | REOPENED_EVENT（GraphQL の `PullRequestTimelineItemsItemType` にあり、`ReopenedEvent` は `actor` と `createdAt` を持つ。スキーマを照会して確認、2026-11-12） |
| Added to／Removed from merge queue | ADDED_TO_MERGE_QUEUE_EVENT／REMOVED_FROM_MERGE_QUEUE_EVENT |

同じ出来事が Mentioned と Comment の両方に該当するときは Mentioned の行だけを生成する。Mentioned の行の投稿者、本文、移動先は、リンクを含むコメント、レビュー、または PR の本文から求める。MENTIONED_EVENT は使用しない。GitHub はレビューコメントでのメンションに MENTIONED_EVENT を生成せず、会話のコメントでもコメントより数秒遅れて生成するためである（所有者の確認、2026-11-05）。引用の返信の中のメンションは user-mention のリンクにならないので、Mentioned にしない。本文の文字列から `@login` や `@org/team` を検索する方法は使用しない。メンションの検知は、取得の契機に関係なく、取得したすべてのタイムラインで行う。

**行のラベル**。行の種類のラベルは表の名前である。ただし長い名前は短くする：Comment on my PR と Comment on other PRs は `Comment`、Reply in a thread I commented in と Reply in a thread I was mentioned in は `Reply`、Review requested to my team は `Review requested`（本文の `for <チームの slug> team` で区別する）、Reaction to my comment は `Reaction`。Merged / Closed は `Merged` と `Closed` に区別する。

**行の本文と移動先**。Review requested の本文は `for you`、Review requested to my team の本文は `for <チームの slug> team` である。Merged、Closed、Reopened の行と Approved の行は、出来事を起こした人を `by <ログイン名>` の形で本文に表示する。Added to merge queue の行も同じである。Removed from merge queue の行は、取り除いた人（チェックの失敗では github-merge-queue、手動では操作した人）を表示し、本文は理由と PR をキューに追加した人である（`Checks failed · added by alice`）。理由は `failed_checks` を `Checks failed`、`manual` を `Removed manually`、`merge_conflict` を `Merge conflict` と表示し、それ以外の値はそのまま表示する。キューに追加した人は、同じ PR の Added to merge queue の出来事のうち、まだ対応させていない最も古いものの actor とする。理由が `merged` の取り除きは、Merged の行で足りるので行にしない。GitHub が出来事の URL を返さない Review requested、Reopened（`ReopenedEvent` の項目は `actor`、`closable`、`createdAt`、`id`、`stateReason` で URL を持たない。スキーマの照会で確認、2026-11-13）、マージキューの行は、PR のページを開く。ただし理由が `failed_checks` の Removed from merge queue の行は、`beforeCommit`（マージキューが作成したコミット）のチェックから、失敗した必須の CheckRun の `detailsUrl`、なければ失敗した必須の StatusContext の `targetUrl`、なければ最初の失敗したチェックの URL、どれもなければ PR の Checks のページ（`/checks`）を開く。失敗は、CheckRun では `conclusion` が SUCCESS、NEUTRAL、SKIPPED 以外の完了したもの、StatusContext では `state` が FAILURE または ERROR のものである。`merge_conflict` では `beforeCommit` が `null` なので PR のページを開く。キューに追加した人の対応（Added to merge queue の actor）は変更しない（`enqueuer` は取り除いた人を返すため）。`MergeQueue` の要求が権限の不足で拒否されたとき（403、または GraphQL の FORBIDDEN と INSUFFICIENT_SCOPES のエラー）も、Removed from merge queue の行はタイムラインの項目から生成する。本文は理由だけで、キューに追加した人を付けない。移動先は、理由が `failed_checks` なら上の順の最後の PR の Checks のページ（`/checks`。`beforeCommit` のチェックを読めないため）、それ以外の理由では PR のページである。ほかの失敗（5xx など）では、その PR の出来事の取得の失敗として取り直す。

**選択とキー**。選択は、タブでは「区画（グループ）の見出し」「カードの見出し」「行」「カードの中の + N more」「Older activity on GitHub」「+ N more PRs（Show less）」を上から順に、Dismissed の一覧ではカードの見出しだけを移る。クリックでも選ぶ。行を選ぶと、その行を既読にする。キーの動作は「キーボード」の表に従う。

**CLI の activity**。アプリに Activity のタブはない。CLI の `activity` は、カードの表示が想定と異なるときの調査のために、Dismiss していないカードの行を新しい順に 1 本で出力する。行は、種類、ラベル、actor と時刻、本文、`owner/repo #番号 · タイトル` と、未読かどうか、Mute の対象かどうかを持つ。

**CLI の絞り込みの意味**。アプリに絞り込みのチップはない。CLI の `list` と `activity` の絞り込みは、Authored by me が author が自分の PR、Assigned to me が assignees に自分を含む PR、Review requested が今も自分または自分のチームにレビューが依頼されている PR（チームは、その owner の Review requested to my team の List がオンのときだけ）である。Group by の `Involvement` のグループも同じ意味で分類する。これは GitHub の事実（`review_requested`）で、Mute を参照しない。カードの `Review requested` の印は、このアプリのレビュー待ち（「レビュー待ちの定義」）である。

検索、Group by、Then by、並び、グループの順番、`+ N more PRs` の計算はすべてアプリが行う。アプリは `list` を絞り込み（`tab`、`filter`、`owner`）も `search` も付けずに、`dismissed` を `include` にして取得する。区画とグループの数は検索に依存しないので、アプリは検索前のカードを持つ必要があるためである。取得は 1 回ごとに 1 往復で完了し、文字を打つたびにデーモンへ問い合わせない。ワイヤの `tab`、`filter`、`owner`、`owners`、`search` は CLI のためだけに持つ。

検索は、検索の文字を空白で単語に分割し、すべての単語が一致した項目だけを表示する。各単語は、次のいずれかに大文字と小文字を区別しない部分一致で一致すればよい：タイトル、`owner/repo#number`（`example-org/api#407` の形）、作者のログイン名、base と head のブランチ名、行の本文、行の actor のログイン名。一致しない PR（PR の項目にもその行の本文と actor にも一致しない PR）を隠す。CLI の `activity` では一致しない行（その PR の項目にもその行の本文と actor にも一致しない行）を隠す。区画とグループの数は変更しない。アプリ（Swift）と CLI の判定（Rust）は同じ規則で、テストは次の例を共有する。

| 検索の文字 | `example-org/api#407` に一致するか | 理由 |
| --- | --- | --- |
| `api 407` | 一致する | `api` と `407` がそれぞれ `example-org/api#407` に含まれる |
| `#407` | 一致する | `example-org/api#407` に含まれる |
| `api #407` | 一致する | 2 つの単語がそれぞれ一致する |
| `API` | 一致する | 大文字と小文字を区別しない |

検索で 0 件になったときは `Nothing matches` を表示する。Group by、Then by、並びは表示の順と区切りだけを決め、カードを隠さない。

**初回、失敗、空**

| 状態 | 表示 |
| --- | --- |
| アカウントがない | メニューバーに shiibar-gh のアイコン 1 つ。押すと「No accounts yet」「Add an account in Settings」と `Add account…` のボタン |
| アカウントに owner がない | ポップオーバーに「No owners yet」「Add an owner in Settings」と Settings ボタンだけ（警告があれば見出しの下の帯は表示する）。設定はそのアカウントを選んだ状態で開く |
| 取得の失敗 | 最初の失敗から 5 分たっても成功していないとき、アイコンに三角。ポップオーバーに黄色い帯「Couldn't reach GitHub · retrying in N min」。N は次の再試行の時刻（`fetch_failed` の警告の時刻）から 0.2 と同じ形式で求める。前回の内容は残す。5 分までは `Updated … ago` の時刻が進まないことだけで示す |
| トークンが無効（401） | アイコンに三角。帯に警告。トークンを差し替えるまでそのアカウントの取得を止める。前回の内容は残す |
| トークンがない（`token reset` のあと） | アイコンに三角。帯に `No token`。登録するまでそのアカウントの取得を止める。前回の内容は残す |
| トークンの期限まで 7 日以内 | アイコンに三角。帯に期限 |
| Keychain を読めない | すべてのアイコンに三角。ダイアログと帯（「Keychain を読めないとき」） |
| API の使用率が 80% 以上 | 帯に警告。見出しの使用量のバーと数字を警告の色にする。間隔は変更しない |
| GitHub の残量が尽きた | アイコンに三角。帯に再開の時刻を付けたエラー。再開まで取得しない |
| All のカードが 0 件 | `No pull requests`。検索で 0 件なら `Nothing matches` |
| Review のカードが 0 件 | `No pull requests to review`。検索で 0 件なら `Nothing matches` |
| Mine のカードが 0 件 | `No pull requests of yours`。検索で 0 件なら `Nothing matches` |
| Dismissed の一覧が 0 件 | `No dismissed pull requests`。検索で 0 件なら `Nothing matches` |

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
| `status_fetch_failed` | 付けない | `Couldn't fetch status for example-org/api #407 · retrying` | — |

**通知 API の取り方**。If-Modified-Since と X-Poll-Interval に従う。`refresh` でも、前回の通知の確認から X-Poll-Interval の秒数がたっていなければ、通知の確認だけを省き、ほかの取得はする。GitHub のドキュメントが X-Poll-Interval に従うよう求めているためである。50 件ずつ、since は前回の最新。既読の同期はしない（GitHub 側の未読は触らない）。

**CLI（AI 連携）**。`shiibar-gh` コマンドで、ポップオーバーと設定でできる操作をすべて持つ。アプリのローカル状態を読み書きするだけで、GitHub には書き込まない。AI エージェントは Bash から呼ぶ（--help と --json で足りる。CLI の存在と主な使い方は CLAUDE.md に数行記述する）。MCP は作成しない。

owner や PR を指す命令は `--account <account>` を必須にする。省略できるのは、`account …`（アカウント名を引数に取る）、`read`（行 id は全体で一意）、`list`／`activity`／`refresh`（`--account` は絞り込み）、`version` だけである。

| コマンド | 動作 |
| --- | --- |
| list [--account \<a\>] [--tab all｜review｜mine] [--owner \<o\>] [--authored｜--assigned｜--review-requested] [--search \<text\>] [--dismissed] [--json] | カードの一覧を出力する。`--tab` の既定は `all`。絞り込みと `--search` の判定はデーモンが行い、アプリと同じ規則（「CLI の絞り込みの意味」）で絞る。`--dismissed` は Dismissed の一覧のカードだけを出力する（`--tab` は無視する）。出力の順は、`all` では Owner の登録の順で、各 owner の中は開いている PR を先にした `Recently updated` の順、`review` では `Doing`、`Todo`、`Waiting`、`Done` の区画の順と順位、`mine` では順位と `Done`、`--dismissed` では Dismiss した時刻が新しい順である。Group by と並びは表示の状態なので持たない。テキスト出力では、配置先（`[review:todo]`、`[mine]`）、レビュー待ちの PR に `[review requested]`、Mute の対象に `[muted]`、Dismissed のカードに残りの日数を付ける |
| status \<pr\> --account \<a\> | 状態ラベルと Review／Checks／Base |
| activity [--account \<a\>] [--owner \<o\>]… [--authored｜--assigned｜--review-requested] [--search \<text\>] [--json] | Dismiss していないカードの行を新しい順に出力する（「CLI の activity」）。`--owner` は複数指定できる。`--search` は `list` と同じ規則で絞る |
| read \<row\>… / read --all --account \<a\> | 行を既読にする（行を選ぶか開いたときと同じ）／Dismiss している PR の行を除くアカウントのすべての行を既読にする（ワイヤの `read_all`。⇧R より範囲が広い） |
| place \<pr\> review doing｜todo｜waiting [--top｜--bottom｜--before \<pr\>] --account \<a\> / place \<pr\> review done --account \<a\> / place \<pr\> mine [--top｜--bottom｜--before \<pr\>] --account \<a\> / place \<pr\> mine done --account \<a\> / place \<pr\> none --account \<a\> | Review の区画への追加と移動、Mine への追加と移動、Review と Mine の `Done` への移動、配置なしへの変更（`Remove from …`）。位置を省略すると、`todo` へは `doing` と `waiting` からの移動なら先頭、それ以外は末尾に配置する（ワイヤの `place` と同じ）。`done` は位置を取らない（`Done` の並びの規則で配置する） |
| dismiss \<pr\> --account \<a\> / restore \<pr\> --account \<a\> | Dismiss と Restore |
| mute pr｜repo｜user \<name\> --account \<a\> / unmute pr｜repo｜user \<name\> --account \<a\> / mutes --account \<a\> [--json] | Mute と解除、Mute の一覧の表示。`<name>` は `pr` では `<pr>`、`repo` では `owner/repo`、`user` ではログイン名 |
| refresh [--account \<a\>] | 今すぐ取得する。定期取得と同じ内容（検索、状況、出来事、通知、Reaction）を取得し、反映が終わってから戻る。Keychain を読めない状態では再読み込みから始める |
| open \<pr｜row\> [--account \<a\>] | その場所の URL を出力する（開くのは呼び元。`<row>` では `--account` を省略できる）。行を既読にしない |
| config get \<key\> / config set \<key\> \<value\> | 設定項目の読み書き（General と Dismissed の項目。`text_size` を含む） |
| version [--json] | CLI 自身の版と、デーモンの `info` の版を 2 行で出力する（`cli: 0.4.0` と `daemon: 0.4.0`。`--json` は `{"cli":"0.4.0","daemon":"0.4.0"}`）。デーモンに接続できないときは CLI の版を出力し、デーモンの行は `daemon: not running`（`--json` では `"daemon":null`）とする |
| reset | DB を読めないときの初期化 |
| account list [--json] / account add / account remove \<account\> / account color \<account\> \<color\> | アカウントの一覧、追加（トークンは標準入力）、削除、色（`none`、`red`、`orange`、`yellow`、`green`、`blue`、`purple`） |
| token set --account \<a\> / token test --account \<a\> / token reset | トークンの差し替え（標準入力）、テスト（標準入力にトークンがあればそれを、なければ保存済みを検証）、Keychain の項目の削除（「Keychain を読めないとき」） |
| owner lookup \<owner\> --account \<a\> | owner の種類と id を `GET /users/{owner}` で求める。見つからなければ `not_found`。owner を登録しない |
| owner list [--account \<a\>] / owner add \<owner｜public\> --account \<a\> / owner remove \<owner\> --account \<a\> / owner enable｜disable \<owner\> --account \<a\> | owner の一覧、追加（`public` は Public）、削除、enabled と disabled の切り替え。`owner add` は `owner lookup` を実行して種類と id を保存する |
| owner notify \<owner\> on｜off --account \<a\> / owner skip-drafts \<owner\> on｜off --account \<a\> | Notifications タブの 2 つのスイッチ |
| owner events \<owner\> --account \<a\> / owner events set \<owner\> \<event\> list｜notify on｜off --account \<a\> / owner events copy \<from-owner\> \<to-owner\> --account \<a\> | 出来事の表の表示、変更、コピー。`<event>` は「ワイヤ形式」の種類の値 |

`<pr>` は owner/repo#number、`<row>` は list／activity が出力する id、`<account>` はアカウントの login、`<owner>` は owner のログイン名または `public`。ログイン名とリポジトリ名の比較は大文字と小文字を区別しない（GitHub の API はログイン名とリポジトリ名を大文字と小文字の違いを問わず解決する。`gh api users/BUFFERINGS` と、GraphQL の `repository(owner:"RUST-LANG",name:"RUST")` が rust-lang/rust を返すことで確認）。`public` は Public を指すので、`public` という owner は登録できない。0.1 の `scope …`、`token set notifications`、`list --needs-action`、`undone`、`settings status`、0.2 の `list --todo`、`activity --todo`、`done`、`todo`、0.3 の `snooze`、`unsnooze`、`list --snoozed`、`owner exclusions …` は残さない。

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
| `list` | account、tab（`all`、`review`、`mine`。省略時は `all`）、owner、filter（`all`、`authored`、`assigned`、`review_requested`）、search（省略可）、dismissed（`exclude`、`only`、`include`。省略時は `exclude`） | `cards` |
| `activity` | account、owners（配列）、filter、search（省略可） | `rows` |
| `status` | account、pr | `card` |
| `read` | row_ids（配列） | — |
| `read_all` | account | — |
| `popover_opened` | account | — |
| `popover_closed` | account | — |
| `place` | account、pr、tab（`review`、`mine`、`none`）、section（`review` では `doing`、`todo`、`waiting`。ほかは省略）、before（PR。省略可）、at（`top`、`bottom`。省略可） | `card` |
| `dismiss`／`restore` | account、pr | `card` |
| `mute`／`unmute` | account、kind（`pr`、`repo`、`user`）、name | `mutes` |
| `mutes_get` | account | `mutes` |
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
| `token_set` | account、token | — |
| `token_test` | account（省略可。省略時は token が必須で、アカウントを作成せずに検証する）、token（省略可） | `results` |
| `token_reset` | — | — |
| `subscribe` | client（`app` または `cli`） | 下の event の流れ |
| `reset` | — | — |
| `info` | — | `version`、`started_at` |
| `shutdown` | — | 応答後に終了 |

`account` の引数はアカウントの login、`owner` の引数は owner のログイン名または `public` で、応答の中の参照は id で行う。`list` の `tab`、`filter`、`owner`、`search` と `activity` の `owners`、`filter`、`search` は CLI のための引数で、アプリは付けずに取得する（「CLI の絞り込みの意味」）。

アカウントの値は `{"id","login","color","token":{"registered","expires_at","last_test"},"updated_at","unread","warnings":[...],"rate_limit":{"graphql":{"used","limit","reset_at"},"rest":{...}},"owners":[...]}` である。`owners` は登録の順で、Public は常に最後である。`id` は GitHub のユーザーの数値の id を 10 進の文字列にしたもの（`"3407303"`）、`color` は `none`、`red`、`orange`、`yellow`、`green`、`blue`、`purple` のいずれかで、`account_color` の不正な値は `invalid` になる。`last_test` は保存済みのトークンの最後のテストの `{"at","results"}`（なければ `null`）。`rate_limit` の値がまだなければ `null`。`updated_at` はそのアカウントの取得が最後に成功して終わった時刻（なければ `null`）、`unread` はメニューバーの青い点の有無（「未読の消え方」）である。owner の値は `{"id","name","kind","github_id","enabled","notify","skip_drafts","pr_count"}` で、`pr_count` はその owner の Dismiss していないカードの数である。`kind` は `org`、`user`、`public` のいずれかである。`id` はデーモンが割り当てる識別子で、ログイン名として解釈しない。`github_id` は `GET /users/{owner}` の数値の `id`（Public は `null`）である。

カードと行の値は 0.1（docs/tasks/M1.md の「応答の項目」）の項目を保ち、`scope` を `owner`（owner の id）に、カードの `mine` を `authored_by_me` に置き換え、カードの `snoozed` と `snoozed_until`、行の `class` と `done` を削除する。カードはさらに `author_avatar_url`（GraphQL の `author.avatarUrl(size: 32)`。`author` が `null` なら `null`）、`assigned_to_me`、`review_requested`（「CLI の絞り込みの意味」の Review requested）、`awaiting_review`（レビュー待ちか。「レビュー待ちの定義」）、`created_at`（GraphQL の `createdAt`）、`updated_at`（GraphQL の `updatedAt`）、`placement`、`muted`、`dismissed_at`、`dismiss_expires_at`、`auto_dismiss_at`、`older_rows`（その PR の行を削除したことがあるか。「カードの中の行」）を持ち、行は `owner`、`kind`、`muted` を持つ。カードの `rows` は保持しているすべての行（20 件まで）で、3 件の表示と `+ N more` はアプリが求める。

- `placement` は配置なしなら `null`、配置していれば `{"tab","section","position"}` である（`position` は Mute の対象を末尾にした表示の順）。`tab` は `review` または `mine`、`section` は Review では `doing`、`todo`、`waiting`、`done`、Mine では `main` または `done`、`position` はその区画の中の順番（0 から）で、デーモンが求める。Dismiss しているカードの `placement` は、復帰したときの配置である。
- `muted` は、カードが Mute の対象になっている理由の配列（`pr`、`repo`、`author`。対象でなければ空）である。行の `muted` は、その行が Mute の対象か（灰色の点）の真偽値である。
- `dismissed_at` は Dismiss した時刻（していなければ `null`）、`dismiss_expires_at` は `Dismissed` の一覧から除く時刻（`dismissed_at` に m 日を加えた時刻。していなければ `null`）である。`auto_dismiss_at` は自動の Dismiss を行う時刻（「Dismiss」の規則で求める）で、予定がなければ `null` である（開いている PR、Review または Mine の `Done` の外の区画に配置したカード（配置なしのカードには予定がある）、Restore したカード、例外の行があるカード、Dismiss しているカード）。

`notify` の `notification` も 0.1 の形を保ち、`scope` を `account`（アカウントの id）と `owner`（owner の id）に置き換える。まとめ通知は `title` と `subtitle` を持ち、`body` は `null` である。カードと行も `account` を持つ。

出来事の種類の値（`event`、行の `kind`）は `review_requested`、`team_review_requested`、`mentioned`、`team_mentioned`、`comment`、`comment_other`、`reply`、`reply_mentioned`、`reaction`、`approved`、`changes_requested`、`checks_failed`、`checks_passed`、`conflicts`、`mergeable`、`merge_queue_added`、`merge_queue_removed`、`merged_closed`、`reopened` である。行の `kind` では `merged_closed` の代わりに `merged` と `closed` を使用する。`events` は種類ごとの `{"list","notify"}`、`mutes` は `{"repos":[name],"users":[name],"prs":[<pr>]}` である。

`place` は、Review と Mine の配置と順位を変更する。`before` を指定するとその PR の直前に、`at` を指定すると区画の先頭または末尾に配置する。どちらも省略すると、`todo` へは `doing` と `waiting` からの移動なら先頭、それ以外は末尾に配置する。`section` の `done` は、`review` と `mine` の `Done` への移動である（`mine` の `section` は省略、`main`、`done` のどれか）。`done` へはカードが `Done` に入った時刻で並べるので、すでにそのタブの `Done` にあるカードは移動せず `ok` である。`Done` のカードは、開いているかどうかに関係なく、ほかの区画へ移動でき、`none` にもできる。`before` の PR が同じ区画にない、`before` の PR が Mute の対象（移動するカードが Mute の対象かどうかに関係しない）、`done` への配置での `before` と `at`、自分が作成した PR の `review` と `none`、Dismiss しているカードへの `place` は `invalid` である。マージまたはクローズされた配置なしの PR への `review` と `mine` は、`section` と位置を無視して、そのタブの `done` に配置する。Mute の対象のカードの移動は「Review」の規則に従い、`at` と位置の既定は Mute の対象のカードの間で解釈する。Mute の対象のカードに `at` の `top` を指定すると、区画の先頭の順位を付ける。Mute の間は Mute の対象のカードの先頭に表示し、Mute を解除すると区画の先頭に表示する。Mute の対象のカードを `before` で移動すると、`before` の PR（Mute の対象でないカード）の直前の順位を付ける。この順位は Mute を解除したあとに適用し、Mute の間は、Mute の対象のカードの中でこの順位に従って並べる（`before` に Mute の対象のカードを指定するのは、引き続き `invalid` である）。disabled の owner の PR と読めなくなった PR への `place`、`dismiss`、`restore` は `not_found` である。`dismiss` は Dismiss していないカードに、`restore` は Dismiss しているカード（`Dismissed` の一覧にあるもの）だけを受け付け、それ以外は `invalid` である。知らない PR は `not_found` である。`mute` の `name` は、`pr` では `owner/repo#number`、`repo` では `owner/repo`、`user` ではログイン名で、形が不正なら `invalid`、すでにあれば変化なしで `ok` である。`unmute` の対象がなければ `not_found` である。`mute` の `pr` は、そのアカウントの知っている PR だけを受け付ける。

`owner_lookup` は `GET /users/{owner}` で owner の種類と id を求め、owner を登録しない。GitHub のログイン名として不正な owner（英数字とハイフン以外を含む、ハイフンで始まるか終わる、40 文字以上）は問い合わせずに `invalid`、見つからなければ `not_found`、接続できなければ `unreachable`、ほかの失敗は理由を付けた `internal` にする。`owner_add` は同じ問い合わせを行い、成功したときだけ登録する。`account_add` と `token_set` の持ち主の確認が失敗したときの `code` は、持ち主が異なれば `invalid`（`error` は `Belongs to octocat`）、接続できなければ `unreachable` である。

`subscribe` は最初に `{"event":"snapshot","accounts":[...],"keychain":"ok"|"unavailable"|"unreadable","db_unreadable":false}` を送る。DB を読めない間も `subscribe` と `info` は使用でき、`db_unreadable` が真になる。以降は `{"event":"account_changed","account":{...}}`、`{"event":"account_removed","id":"..."}`、`{"event":"keychain_changed","keychain":"..."}`、`{"event":"notify","notification":{...}}`、`{"event":"config_changed","key":"...","value":...}` を送る。`account_changed` は、アカウントの値が変化したとき、またはそのアカウントのカード、行、Mute が変化したときに送り、クライアントは `list` で一覧を再取得する。`keychain` は最初の読み込みまでは `ok` である。`config_changed` は、`config_set` で設定の値が変化したときに、保存してからすべての購読者に送る。`value` は `config_get` が返す値である。同じ値の `config_set` と、拒否した値では送らない。アプリはこれで `launch_at_login` の変更を知り、ログイン項目を登録または解除する（「Launch at login の同期」）。また `appearance`（`system`、`light`、`dark`）の変更を、ポップオーバー、常時表示ウインドウ、設定画面、メニューバーのアイコンにすぐ反映し、`text_size` の変更を、ポップオーバーと常時表示ウインドウにすぐ反映する。

設定のキーは `launch_at_login`、`appearance`、`text_size`（整数、9〜18。範囲外は `invalid`）、`status_interval_minutes`、`reactions_interval_minutes`、`auto_dismiss_after_days`（n。0 以上の整数）、`dismissed_keep_days`（m。1 以上の整数）である（範囲は「設定項目」）。0.1 の `graphql_cost_cap`、`notify_*`、`bot_comments`、`include_team_requests`、0.3 の `snooze_return_time`、`keep_watching_days`、`drop_after_days` はない。`dismissed_keep_days` を変更すると、Dismiss しているすべてのカードの `dismiss_expires_at` に反映する。`auto_dismiss_after_days` の変更も、まだ Dismiss していない閉じた PR（`auto_dismiss_at`）に反映する。

DB を読めない状態に移行したとき、およびその状態から `reset` で戻ったとき、デーモンは `subscribe` の接続をすべて切断する。クライアントは再接続し、`snapshot` で新しい状態を受け取る。DB を読めない間の `accounts` は空の配列とする。`reset` のあとの最初の取得で Keychain を読み込み、アカウントを復元する。

`popover_opened` と `popover_closed` は、メニューバーの青い点（「未読の消え方」）、自動の Dismiss と `Dismissed` の一覧からの除去（「Dismiss」）のために開いている状態を伝える。行の既読は変更しない。`popover_opened` で記録した開いている状態は、`client` が `app` の接続が切れたときとデーモンの起動時に解除する。アプリの異常終了で `popover_closed` を受信できなくても、メニューバーの青い点を付けられるようにするためである。アプリは再接続時に、開いているアカウントの `popover_opened` を再送する。

`read` は指定した行の未読を下ろす。存在しない行 id があれば `not_found` を返し、何も変更しない。`read_all` は、Dismiss している PR の行を除く、そのアカウントのすべての行の未読を下ろす。Mute の対象の行や List オフで表示しない行も含む。ポップオーバーの ⇧R は `read_all` を使用せず、表示している行の id を `read` に列挙して送る（「未読の消え方」）。`open` は URL を返すだけで、行を既読にしない。行を開いたときの既読は、アプリが `read` を送って付ける。

アカウントの `warnings` と `refresh` の応答の `warnings` の要素は `{"kind":"...","account":<アカウントの id または null>,"owner":<owner の id または null>,"message":"...","until":<epoch 秒または null>,"url":<文字列または null>}` である。`kind` は「警告の表示」の表の値のいずれかで、`owner` は `sso_required`（常に owner を示す）、`events_fetch_failed`、`status_fetch_failed` で owner を示し、`until` は `fetch_failed` では次の再試行の時刻、`rate_limited` では再開の時刻、`token_expiring` ではトークンの期限、`url` は `sso_required` の承認の URL である。`keychain_unavailable` と `tokens_unreadable` はすべてのアカウントに付く。

トークンは `account_add`、`token_set`、`token_test` の中にだけ現れる。デーモンはこれらの要求をログに出力しない。

`refresh` は、取得と反映が終わってから応答する。取得の失敗も `ok` で応答し、失敗は `warnings` で示す。取得中に受信した `refresh` は、実行中の取得の完了を待って応答する。上限による停止中は取得せず、すぐに上限による停止の警告と再開の時刻を返す。

### CLI の終了コード

0 成功、1 接続エラー、内部エラー、不正な値、使用法の誤り（デーモン不在を含む）、GitHub に接続できない、Keychain を読めない、2 該当なし（`not_found`）。不正な設定値は保存しない。`version` はデーモンに接続できなくても 0 で終了する。

### 行の状態遷移

行の鍵は GitHub の出来事の node id。node id を持たない出来事は、状態変化なら PR の id、種類、検知時刻から、Reaction ならコメントの id、種類、検知時刻から合成する。同じ出来事から行を二重に生成しない。

| 契機 | unread |
| --- | --- |
| 行の生成 | 立てる（List がオフの種類、自分が再オープンした Reopened の行では立てない） |
| `read`（行を選んだ、または開いた） | 下ろす |
| `read_all`（CLI の `read --all`） | Dismiss している PR の行を除く、そのアカウントのすべての行で下ろす |
| PR の行が 20 件を超えた | 古い行を削除する（未読でも削除する。「カードの中の行」） |

行の状態は未読だけである。削除した行の id への `read` は `not_found` である。Mute の対象かどうかは、行の生成時ではなく、表示のたびに今の Mute から求める（`muted`）。`popover_opened` と `popover_closed` は行の状態を変更しない。

### カードの状態

PR ごとの状態は、配置（なし、Review の区画と順位、Mine の区画と順位）と Dismiss（していない、`Dismissed` の一覧にある）である。Dismiss の記録だけが残る PR はカードを持たない。

| 契機 | 配置 | Dismiss |
| --- | --- | --- |
| 開いている PR を新しく発見した | 自分が作成した PR は Mine の末尾。そうでなければなし（レビューの依頼の行を生成すれば次の行） | していない |
| 閉じた PR を新しく発見した（復帰の契機の行を生成した記録のない PR） | 自分が作成した PR は Mine の `Done`、そうでなければなし（Review requested の行を生成すれば次の行で Review の `Done`。生成する行は復帰の契機の 4 つの行だけで、チーム宛ての依頼の行は生成しない）。位置と n 日の起点は検知の時刻（n 日を数えるのは契機が Review requested または Reopened の行のとき。「Dismiss」） | していない |
| マージまたはクローズされた配置なしの PR に `Add to Review`／`Add to Mine` | そのタブの `Done` | 変更しない |
| Review requested または Review requested to my team の行を生成した（List がオン） | 配置なしなら Review の `Todo` の末尾（マージまたはクローズされた PR は Review の `Done`）。配置済みなら変更しない | 変更しない（Dismiss している PR はこの行で復帰しない。自分宛ての Review requested は次の「復帰の契機」） |
| 復帰の契機の行を生成した（「Dismiss」） | 変更しない（記録がなければ新しく発見した PR と同じ） | していない |
| マージまたはクローズを検知した（状況の取得） | `Done` に移動する（`Done` に入る前の区画と順位を記録する。すでに `Done` にあるカードは残る）。`Done` に入った時刻はこの検知の時刻。配置なしは変更しない。移動はこの検知の時点の 1 回だけで、以降の取得では移動しない | 変更しない。`Done` にある間と配置なしの間は n 日後に自動の Dismiss（n 日はこの検知から数える） |
| 再オープンを検知した（状況の取得） | `Done` にあるカードは記録した区画と順位に戻す。`Done` の外のカードは変更しない | していない。自動の Dismiss の例外（Restore したこと、マージまたはクローズのあとの Mentioned と Reply の行）を解除する |
| `place` で `Done` へ移動した | そのタブの `Done`。入った時刻は操作の時刻（すでにその `Done` にあれば変更しない） | 変更しない。マージまたはクローズされた PR は n 日後に自動の Dismiss（n 日はこの時刻と検知の時刻の遅いほうから数える） |
| `place` で `Done` から他の区画へ移動した | 指定どおり。マージまたはクローズされた PR も、以降の取得で `Done` に戻さない | 変更しない。`Done` の外にある間は自動では Dismiss しない |
| `place`（上記以外） | 指定どおり | 変更しない |
| `dismiss`、自動の Dismiss | 変更しない | `Dismissed` の一覧に移る |
| `restore` | 変更しない | していない。再オープンを検知するまで、自動では Dismiss しない |
| Dismiss から m 日が経過した | 削除する | 開いている PR は Dismiss の記録だけを残し、閉じた PR は何も残さない |

- 自動の Dismiss と m 日の経過による削除は、ポップオーバーを開いている間は行わず、`popover_closed` を受信したとき（開いていないときは期限を過ぎた時点）に行う。
- disabled の owner の PR と読めなくなった PR も、この表のとおり状態を保ち、n 日と m 日を数える（「カードの表示と監視」）。
- 並びは、Review と Mine の `Done` 以外の区画では利用者の順位（Mute の対象を末尾）、`Done` ではカードが `Done` に入った時刻の降順（Mute の対象を末尾）、All ではアプリが「All」の規則で求める。All の並びの `Recently added` の基準はカードの追加時刻で、カードが初めて表示された時刻のまま更新しない。
- レビュー待ち（`awaiting_review`）は、表示のたびに（`list` の応答と `account_changed` を生成するたびに）PR の今の状態、保存した最新の依頼の時刻、チームの List から求める。

### 通知の判定

デーモンが行の生成時に通知の要否を判定し（表の Notify、owner の Notify、Skip draft pull requests、Mute。Mentioned は Mute を問わない）、結果を行に保存する。アプリの再起動で再通知しない。Dismiss している PR では、復帰の契機の行だけを生成し、同じ判定で通知する。通知を渡す時点でも、owner の Notify、enabled、PR を読めるか、Mute の対象か（Mentioned を除く）、PR を Dismiss しているかを確認し、オフ、disabled、読めなくなった PR、Mute の対象、Dismiss している PR のいずれかなら通知せず記録を消去する。後からオンに戻しても、消去した分は通知しない。

デーモンは通知をアプリへ渡したかを記録する。渡せなかった通知は、アプリの再接続時に「macOS 通知」のまとめ方に従って通知する（owner ごとに 2 件以上なら `N new events` のまとめ通知）。アプリの停止中に起きた出来事も、起動後の取得で検知した分を同じようにまとめる。渡した通知はアプリを再起動しても再通知しない。既読にした行と削除した行の通知は、渡せていなくても通知せず、記録から除く。

### 定数

| 定数 | 値 |
| --- | --- |
| 状態ディレクトリ | `~/.local/state/shiibar-gh/`（`SHIIBAR_GH_STATE_DIR` で変更） |
| ログレベル | info（`SHIIBAR_GH_LOG` で変更） |
| アプリの再接続 | 1 秒から倍々、上限 30 秒 |
| 取得の失敗の再試行 | 5、10、20、40 秒と延ばし、以降は 40 秒を繰り返す。どの待ち時間も設定の間隔を超えない |
| 取得の失敗の帯と三角を表示するまで | 最初の失敗から 5 分 |
| id でまとめる GraphQL の要求の件数 | `Status`、`Compare`、`Contexts`、`Reactions` は 50 件、`Events` は 5 件（502 と 504 では半分に分割して再試行する） |
| 発見の範囲（開いている PR の `involves:@me` と `reviewed-by:@me` の検索の D） | 14 日 |
| 区画の表示数 | 上位 5 枚（6 枚以上で `+ N more PRs`） |
| 自動の Dismiss までの日数（`auto_dismiss_after_days`） | 既定 3 日 |
| Dismissed の一覧に残す日数（`dismissed_keep_days`） | 既定 7 日 |
| 操作の失敗の帯を表示する時間 | 10 秒（次の操作でも消す） |
| 文字の大きさ（`text_size`） | 既定 12 pt、範囲 9〜18 pt の整数 |
| 状態ディレクトリの権限 | ディレクトリ 0700、DB 0600 |

## 未決

- [ ] `repo` スコープの classic PAT で statusCheckRollup の個々の CheckRun と、非公開リポジトリのマージキュー（mergeQueueEntry、タイムラインのイベント）を取得できるか。できれば失敗したチェックの名前を GitHub Actions の job から求める回り道をやめられる
- [ ] Removed from merge queue（`failed_checks`）の行の移動先の規則は、公開リポジトリで GitHub Actions を使用する 1 つずつのマージキュー（bevyengine/bevy）でだけ確認した。非公開リポジトリのマージキュー、複数の PR をまとめて試すマージキュー、GitHub Actions 以外の CI では確認していない
- [ ] メンションの判定は、bodyHTML の `user-mention` のリンク（`class="user-mention"` と、ユーザーのページへの `href`）と `team-mention` のリンク（`class="team-mention"` と、チームの databaseId を表す `data-id`）に依存する。この HTML の形は API の仕様ではないので、GitHub が変更すると判定できなくなる
- [ ] 1 つの PR が同時にマージキューに 2 回追加されることがあるか、取り除きが追加の順と異なる順に起きることがあるか（Removed from merge queue の行の、キューに追加した人の対応に影響する。ドキュメントに記載がなく、確認していない）
- [ ] `GET /notifications` の応答に、SSO を承認していない organization の分が含まれず `X-GitHub-SSO` が付くか（ドキュメントは REST の応答一般について記載している。所有者は SSO の organization に属していないので確認できない）
- [ ] SSO の承認が必要という警告の動作全体（SSO を有効にした organization で確認できていない）
- [ ] Public の要求と、複数の owner にまたがる要求（通知、チームの所属）で、1 つの organization への 403（`X-GitHub-SSO` が承認の URL だけの形）を受けたとき、その 403 を owner に結び付けられない。今はその要求の失敗として扱い、`sso_required` の警告は付けない（「トークン」）
- [ ] `nodes(ids:)` で、トークンに権限のない PR（アクセスを失った非公開リポジトリなど）が、`null` と FORBIDDEN のエラーで返るか、`null` と NOT_FOUND のエラーで返るか（実際の応答で確認していない。実装は、NOT_FOUND のエラーを付けた `null` だけを読めなくなった PR とし、ほかの `null` は状況の取得の失敗として扱う。「カードの表示と監視」）
- [ ] `x-oauth-scopes` の `write:org` と `admin:org` が `read:org` を含むとみなしてよいか（docs.github.com の「Scopes for OAuth apps」は `user` の入れ子だけを明記している。2026-11-09 に確認。実装はこの 2 つを `read:org` とみなす）
- [ ] 通知の書き込みと配信の記録の間にデーモンが強制終了すると、次の再接続のまとめ通知で 1 件多く数える場合がある（M1 から引き継いだ既知の動作で、変更しない）
