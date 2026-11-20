# WinSCP Mac — WinSCP の macOS 版

[WinSCP](https://winscp.net/) の使い勝手をそのままに、Swift / AppKit で macOS 用に作り直したファイル転送ソフトです。
(元の WinSCP は C++Builder と Win32 API で書かれているため、Mac ではそのまま動きません。ソースは `macos/` にあります。
元の WinSCP の説明は [readme.winscp.md](readme.winscp.md) にあります。)

## できること

| 機能 | 内容 |
|---|---|
| プロトコル | **SFTP** / **SCP** (macOS の `ssh` を使用。パスワードは最初の 1 回だけ聞きます) / **FTP** / **FTPS** (明示的・暗黙的 TLS) |
| ログイン画面 | WinSCP と同じサイトマネージャー: 保存済みサイトの木 (フォルダ分け)、新しいサイト / 複製 / 名前変更 / 削除、パスワードはキーチェーンに保存 |
| コマンダー画面 | 左にローカル、右にリモートの 2 画面。戻る / 進む / 親 / ルート / ホーム / 更新、パスの直接入力、列の並べ替え |
| 操作 | **F2** 名前変更 / **F4** 編集 / **F5** コピー / **F6** 移動 / **F7** フォルダ作成 / **F8** 削除 / **F9** プロパティ / **F10** 終了、Tab でパネル切り替え、Backspace で親ディレクトリ、Enter で開く |
| 転送 | フォルダごと、ドラッグ＆ドロップ (パネル間・Finder から・Finder へ)、上書き確認 (はい / すべてはい / いいえ / すべていいえ / 新しい場合のみ)、更新日時の保持、進行状況と中止 |
| 編集 | リモートのファイルを手元のエディタで開き、保存するたびに自動でアップロード |
| その他 | パーミッションの変更 (再帰も可)、ディレクトリの比較、コンソール (コマンド実行)、ターミナルで開く (Tera Term Mac があればそれで)、セッションはタブで複数 |
| 移行 | Windows 版の **WinSCP.ini** からサイト (パスワード含む) を読み込み、`~/.ssh/config` のホストも読み込み可 |

## ビルド

```sh
cd macos
./scripts/bundle.sh          # build/WinSCP Mac.app
./scripts/bundle.sh --dmg    # 配布用 DMG (Apple Silicon / Intel 両対応、署名・公証)
swift test                   # テスト (この Mac の sftp-server とシェルを使う)
WINSCPMAC_LIVE=1 swift test  # 公開テストサーバー test.rebex.net も使う
```

macOS 11 以降。

## ライセンス

WinSCP と同じ GNU GPL v3 です ([macos/LICENSE](macos/LICENSE))。アイコンは WinSCP のものを使っています。
