# 開発メモ

開発の進め方と手順を記載する。挙動の正は [DESIGN.md](DESIGN.md)、見た目の正は [design/](design/) である。

## レビューと検証の体制

マイルストーンは `docs/tasks/M<n>.md` の指示書に従って進める。順序は固定で、後の段階を先に実行しない。

| 段階 | 担当 | 内容 |
| --- | --- | --- |
| 1. 指示書レビュー | レビューエージェント | DESIGN.md と指示書の矛盾、抜け、実装前に決定が必要な事項を確認する |
| 2. 実装 | 実装エージェント | 指示書の範囲を実装し、テストを追加する |
| 3. 仕様との比較 | レビューエージェント | 実装を DESIGN.md の遷移表、ワイヤ形式、定数と比較する |
| 4. 独立検証 | 検証エージェント | 実装を知らない状態で仕様と指示書から期待動作を導出し、実際のデーモンをブラックボックスで検証する。コードは最後に、テストの抜けを確認するためにだけ参照する |
| 5. 修正と再確認 | 実装エージェントと検証エージェント | 指摘を修正し、指摘した担当が修正を確認する。合意するまで繰り返す |
| 6. 所有者の確認 | 所有者 | 実機で動作を確認し、push を判断する |

オーケストレーターは指示書の作成、エージェントの起動、結果の比較、所有者への確認を担当し、実装はしない。

## 判断の分担

次の事項はエージェント間の合意で進める。

- 内部設計とコードの構成
- DESIGN.md のとおりに動作させるためのバグ修正
- テストの追加
- ローカルブランチへのコミット

次の事項は所有者に確認する。

- DESIGN.md に記載のない動作の決定
- DESIGN.md の変更、または DESIGN.md と異なる実装
- 方針に関わる依存クレートの追加
- エージェント間で合意できない事項
- push。リポジトリは public であり、push すると公開される

## 外部仕様の確認

GitHub の API、クレートのバージョン、Rust と macOS の挙動は、記憶だけで記述しない。公式ドキュメント、GraphQL スキーマ、公開リポジトリの実データ、`cargo search` などで確認し、確認方法を記録する。確認できない事項は DESIGN.md の未決に記載し、推測で実装しない。

## 依存クレートのクールダウン

公開から 7 日たっていないクレートのバージョンは使用しない。この規則は、Cargo.lock に新しく解決されたすべてのクレート（ほかのターゲット向けのクレートを含む）に適用する。依存クレートを追加または更新するときは、crates.io の API でバージョンの公開日を確認し、確認した日付を記録する。Cargo の `min-publish-age`（`[registry] global-min-publish-age`）はこの規則を設定で強制できるが、unstable の機能（`-Z` を指定する nightly だけ）で、安定版の Cargo は無視するので使用しない（doc.rust-lang.org/cargo/reference/unstable.html で確認）。この機能が安定版に含まれたら、Cargo の設定に移す。

## セットアップ

- Rust は `rust-toolchain.toml` でバージョンを固定する。rustup が自動で取得する
- `swift test` には Xcode 本体が必要である

## よく使用するコマンド

```sh
cargo build
cargo test
cargo clippy --all-targets -- -D warnings

# Run the daemon in a sandboxed state directory
SHIIBAR_GH_STATE_DIR=$(mktemp -d) SHIIBAR_GH_LOG=debug cargo run -p shiibar-ghd -- --foreground

# App tests, with the real daemon of the dev-ingest build
cargo build -p shiibar-ghd --features dev-ingest
SHIIBAR_GH_TEST_DAEMON=$PWD/target/debug/shiibar-ghd swift test --package-path app

# The optimized app build, with warnings as errors
swift build --package-path app -c release -Xswiftc -warnings-as-errors
```

最適化ありのビルドは、インストールとリリースのスクリプトが行うビルドと同じである。最適化の処理だけが報告する警告があり、最適化なしのテストのビルドでは検出できないので、CI の `app` のジョブでも、警告をエラーとしてこのビルドを実行する。

`SHIIBAR_GH_TEST_DAEMON` を指定しないと、実際のデーモンを使用するテストは省略される。

デモのモード（`scripts/perf/demo.sh`）は、作成したデータを持つ `dev-ingest` のデーモンと、メモリーだけの UserDefaults を使用するアプリを起動し、実際の状態ディレクトリ、Keychain、GitHub に触れずに画面を操作できる。`SHIIBAR_GH_DEMO_REFRESH_SECONDS`（0〜60 の秒数。デモのモードだけ）を指定すると、Refresh（見出しのボタンまたは ⌘R）の応答をその秒数だけ保ち、回転する Refresh のアイコンを確認できる。指定しなければ、デモのデーモンはすぐに応答する。

## 開発版のインストール

`scripts/dev-install.sh` は、デーモン、CLI、アプリをリリースモードでビルドし、`~/Applications/Shiibar GH(Dev).app` を組み立てて（アプリの名前も `Shiibar GH(Dev)` にする。Finder、Dock、アプリの切り替えで、リリースのビルドと区別するためである。アプリの識別子はリリースと同じなので、Keychain、通知の許可、設定は共通である。以前の名前 `~/Applications/Shiibar GH.app` の開発用のインストールが残っていれば、止めて削除する）、ローカルの固定の署名の ID（`shiibar-gh-local-signing`。初回にログインキーチェーンに作成する）で hardened runtime を付けて署名し、`~/.local/bin/shiibar-gh` を同梱の CLI へのリンクにして、アプリを起動する。実行中のアプリとデーモンは先に止める。`CFBundleShortVersionString` は、ワークスペースのバージョンに `-dev` を付けた値にする（`0.9.1-dev`）。About の画面と Finder の「情報を見る」で、リリースのビルドと区別するためである。デーモンのバージョンには付けない。アプリは、デーモンのバージョンと比較するときに `-dev` を除く。`CFBundleVersion` は実行の時刻にする。アイコンのキャッシュが版で区別されるためである。

`scripts/dev-uninstall.sh` は、ログイン項目の登録、アプリ、CLI のリンク、残ったデーモン、署名の ID を削除する。`--purge` を付けると、状態ディレクトリ、アプリの UserDefaults、Keychain のトークンの項目（`shiibar-gh token reset`）も削除する。0.1 の Keychain の項目（service `shiibar-gh`、account `tokens`）は削除しない。通知の許可は、システム設定の通知から利用者が削除する。

どちらも `~/Applications`、ログイン項目、キーチェーンを変更するので、エージェントは実行しない。

アプリが起動したデーモンの標準エラー出力は、状態ディレクトリの `shiibar-ghd.log` に出力する。デーモンを再び起動すると、前のログを `shiibar-ghd.previous.log` に移す。

## リポジトリの保護

GitHub の ruleset を 2 つ設定している（どちらも有効で、迂回できる利用者はいない。2026-11-22 に設定）。

- `protect-main`：既定のブランチ（main）の削除と、履歴を書き換える push を禁止する。main への変更はプルリクエストを必須にし（承認の人数は 0。作成者は自分のプルリクエストを承認できないため）、CI の 4 つのジョブ（`test`、`app`、`cask`、`deny`）の成功を必須にする。必須のジョブは、GitHub Actions が報告した結果だけを数える。CI を別の仕組みに移すときは、この指定も変える。そのため、main には直接 push できず、CI のどれかが失敗しているプルリクエストはマージできない
- `protect-release-tags`：`v` で始まるタグの削除と付け替えを禁止する。誤って push したタグを削除するときは、この ruleset を一時的に無効にする

CI のジョブの名前を変更するとき、またはジョブを特定の変更でだけ実行するようにするときは、`protect-main` の必須のジョブも合わせて変更する。必須のジョブが実行されないプルリクエストは、マージできなくなるためである。

適用されるルールは `gh api repos/<owner>/<repo>/rules/branches/main` で確認できる。

## リリース

1. Cargo.toml の `[workspace.package] version` を、リリースする番号にしてコミットし、プルリクエストで main にマージする（main には直接 push できない。「リポジトリの保護」）。公開の直後に上げた仮の番号（手順 5）がリリースする番号と同じなら、この手順は不要である
2. main のそのコミットに `vX.Y.Z` のタグを付けて push する。タグは push したあと削除も付け替えもできないので（「リポジトリの保護」）、版の番号とコミットを確かめてから push する。`.github/workflows/release.yml` が、タグと版の一致を確かめ、Developer ID で署名し、公証、staple、zip をして、下書きの GitHub Release を作成する
3. 下書きの本文を shiibar-cc のリリースと同じ形式に差し替える：リード 1 文（`Shiibar GH X.Y.Z は…`に相当する英文）、利用者の視点の節（機能ごとの見出し、`## Fixed`、`## Changed`。必要なものだけ）、最後に `## Commits` の見出しの下に前のタグからのコミットの件名を新しい順に列挙する（`git log --format='- %s' vA.B.C..vX.Y.Z --no-merges`）。GitHub が自動生成する「What's Changed」と Install の節は載せない。文言は所有者の確認を経てから公開する。本文の差し替えは `scripts/release/draft.sh notes vX.Y.Z <本文のファイル>` で行う。下書きを `gh release edit` や API で直接変更しない。`tag_name` を含めない変更で、下書きの `tag_name` が `untagged-…` になることがあるためである（shiibar-cc のリリースで発生した。`draft.sh` は、変更のたびに `tag_name` を送り、操作の前後に `tag_name` を読み直して、食い違えば止まる）
4. 下書きの zip を実機で確かめてから、`scripts/release/draft.sh publish vX.Y.Z` で公開する。`draft.sh` は、公開の前後に `tag_name` を確かめ、最後に zip の URL が 200 または 302 を返すことを確かめる。公開すると `.github/workflows/bump-cask.yml` が `bufferings/homebrew-tap` の cask を更新する（終わったら、tap の cask の `version` と `sha256` を確かめる）。`tag_name` が `untagged-…` のまま公開された場合は、`tag_name` を直したうえで下書きに戻し（`gh api -X PATCH repos/bufferings/shiibar-gh/releases/<id> -f tag_name=vX.Y.Z -F draft=true`。`<id>` は `draft.sh` のエラーに出る）、`draft.sh publish` をもう一度実行する。`bump-cask.yml` の再実行では直らない（正しい `tag_name` は、新しい公開の出来事でだけ届くため）
5. 公開の直後に、Cargo.toml の `[workspace.package] version` を次の番号（まずパッチ。0.9.0 を公開したら 0.9.1）に上げてコミットし、プルリクエストで main にマージする

バージョンの決まりは次のとおりである（shiibar-cc と同じ）。

- main の Cargo.toml の version は、公開済みの番号より後の番号を指す。公開の直後はパッチを上げた仮の番号にし、次のリリースの内容が決まった時点で、内容に合わせて上げ直す（機能を含むリリースは 0.x、修正だけのリリースは 0.x.y を上げる）。仮の番号のままリリースしなかった番号は、欠番になる
- 開発版のインストール（`scripts/dev-install.sh`）は、その番号に `-dev` を付けて表示する（`0.9.1-dev`）。公開済みのビルドより新しいことが番号で分かり、デーモンのバージョンも公開済みのビルドと異なるので、開発版のアプリは公開済みのビルドのデーモンを使用せずに入れ替える

`release.yml` を手動（workflow_dispatch）で実行すると、リリースを作成しない試走になる。署名、公証、staple、zip までを行い、zip をワークフローの成果物に残す。必要な Secrets は `DEVELOPER_ID_CERT_P12`、`DEVELOPER_ID_CERT_PASSWORD`、`APPLE_API_KEY_P8`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER_ID`、cask の更新には `TAP_PUSH_TOKEN` である。
