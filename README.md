# shiibar-gh

macOS menu bar app for the GitHub pull requests you are involved in: what
needs your action and what happened, per owner and for public repositories.
It only reads from GitHub. See `docs/DESIGN.md` and `CLAUDE.md`.

**Several GitHub accounts.** Each account has its own menu bar icon and one
classic personal access token (scopes `repo`, `notifications`, `read:org`).
Under an account you add owners (organizations or personal accounts) and,
if you like, Public. Version 0.2 does not read the saved state or tokens of
0.1: add your accounts again.

## Install / Uninstall

**Requirements**: macOS 14 (Sonoma) or later, Apple Silicon, and
[Homebrew](https://brew.sh). Intel Macs are not supported.

```sh
brew install --cask bufferings/tap/shiibar-gh
```

This installs `Shiibar GH.app` to `/Applications` and links the
`shiibar-gh` command into Homebrew's `bin`. Open Shiibar GH once (from
Spotlight or `/Applications`): it asks for the notification permission and
registers itself to launch at login. Then add an account in Settings ›
Accounts.

To uninstall:

```sh
brew uninstall --cask shiibar-gh
```

The tokens stay in the Keychain (service `shiibar-gh`, account `accounts`).
Run `shiibar-gh token reset` before uninstalling, or delete the item in
Keychain Access. `brew uninstall --zap --cask shiibar-gh` also removes the
saved state.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or
  <https://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
