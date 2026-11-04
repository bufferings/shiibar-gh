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
```
