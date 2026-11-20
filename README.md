# WinSCP Mac — WinSCP の macOS 版 (非公式)

> **⚠️ 現時点では非公式 (アンオフィシャル) です。**
> このプロジェクトは個人による WinSCP の macOS への移植で、WinSCP の作者 (Martin Přikryl 氏) や WinSCP プロジェクトとは関係がなく、公認されたものではありません。
> 「WinSCP」の名前とアイコンの使用については作者に許可をお願いしているところで、確認が取れるまでは正式な公開・配布はしません。
> Mac 版についての質問・不具合は WinSCP 本家ではなく、[このリポジトリの Discussions](https://github.com/satorunet/winscp_mac/discussions) へお願いします。
>
> **This is currently an UNOFFICIAL macOS port of WinSCP.** It is not affiliated with or endorsed by the WinSCP project or its author, Martin Přikryl.
> Permission to use the "WinSCP" name and icons has been requested; there will be no official release until it is confirmed.
> Please do not contact WinSCP support about this port; use [Discussions](https://github.com/satorunet/winscp_mac/discussions) instead.

[WinSCP](https://winscp.net/) の使い勝手をそのままに、Swift / AppKit で macOS 用に作り直したファイル転送ソフトです。
(元の WinSCP は C++Builder と Win32 API で書かれているため、Mac ではそのまま動きません。ソースは `macos/` にあります。
元の WinSCP の説明は [readme.winscp.md](readme.winscp.md) にあります。)

## WinSCP と同じ画面

画面は WinSCP のソースにある画面定義 (`source/forms/*.dfm`) と公式の日本語訳 (`translations/JP.ini`) から組み立てているので、
ログイン画面・環境設定・高度なサイトの設定・コピー・プロパティ・進行状況などの配置と文言は Windows 版と同じです。
メニュー・ツールバー・アイコンも WinSCP のもの (ScpCommander.dfm / NonVisual.dfm) を使っています。
Mac で使えない項目 (Pageant、PuTTYgen、WebDAV、S3 など) も同じ場所に表示し、灰色にして「Mac 版では未対応です」と出します。

設定は WinSCP.ini と同じキー名で持っているので、Windows 版の **WinSCP.ini** (または .reg) を読み込むと、
サイトだけでなく環境設定やサイトごとの詳細設定もそのまま引き継がれます。WinSCP.ini への書き出しもできます。

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

## サポート

質問・要望・不具合の報告は [GitHub Discussions](https://github.com/satorunet/winscp_mac/discussions) へどうぞ。
アプリのヘルプメニュー →「サポート」からも開けます。
(WinSCP 本家のフォーラムは Windows 版のためのものなので、Mac 版のことはこちらでお願いします。)

## ダウンロード / 更新

[Releases](https://github.com/satorunet/winscp_mac/releases) から DMG をダウンロードし、「WinSCP Mac」をアプリケーションフォルダへドラッグしてください (Apple の公証済み)。
新しい版はアプリが起動時に確認し (環境設定 → 更新、既定は毎週)、「更新」を押すだけで入れ替わります。

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
