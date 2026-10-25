# Karuta

個人用の軽量スクリーンショットアプリ（macOS 14 以上）。CleanShot X を参考に、必要な機能だけを小さく作っています。

## 方針

- メニューバー常駐のみ（Dock アイコンなし）
- AppKit と ScreenCaptureKit だけで作り、外部ライブラリは使わない
- ウィンドウは使うときだけ作り、撮影した画像はすぐ解放する

## 機能（v0.1）

| ショートカット | 動作 |
| --- | --- |
| ⌘⇧4 | 範囲を撮影（Space でウィンドウ選択に切り替え、Esc でキャンセル） |
| ⌘⇧5 | ウィンドウを撮影（クリックしたウィンドウ） |
| ⌘⇧3 | マウスがある画面の全画面を撮影 |

⌘⇧3 / ⌘⇧4 / ⌘⇧5 は macOS 標準のスクリーンショットと同じキーなので、標準側をオフにしてください。「システム設定」>「キーボード」>「キーボードショートカット…」>「スクリーンショット」を開き、すべてのチェックを外します。

撮影後は左下にクイックオーバーレイが出ます。「コピー」でクリップボードへ、「保存」でデスクトップへ保存します。サムネイルを Finder や他のアプリへドラッグすることもできます。6 秒ほどで自動で閉じます（ポインタを乗せている間は閉じません）。

### 注釈エディタ

クイックオーバーレイの「編集」を押すか、サムネイルをダブルクリックすると開きます。

| ツール | キー | 使い方 |
| --- | --- | --- |
| 矢印 | A | ドラッグ |
| 四角 | R | ドラッグ |
| 文字 | T | クリックして入力し、Enter で確定 |
| 番号 | N | クリックするたびに 1, 2, 3… |
| モザイク | M | ドラッグした範囲をぼかす |

色はツールバーで選べます。⌘Z（または Delete）で 1 つ戻し、⌘C でコピー、⌘S でデスクトップに保存します。

## ビルド

Xcode（またはコマンドラインツール）が入った Mac で:

```sh
make run       # build/Karuta.app を作って起動
make install   # /Applications にコピー
```

初回起動時に「画面収録」の許可を求められます。許可したあと、アプリを一度終了してから起動し直してください。

### 再ビルドのたびに許可を求められる場合

標準ではアドホック署名なので、ビルドするたびに macOS から別アプリとみなされることがあります。キーチェーンアクセスの「証明書アシスタント」でコード署名用の自己署名証明書（例: `Karuta Dev`）を作り、次のようにビルドすると許可が維持されます。

```sh
make install SIGN_IDENTITY="Karuta Dev"
```

### アイコン

アプリアイコンの元データは `Support/AppIcon.svg` です。変更したら `make icon`（要 `brew install librsvg`、あると小さくなる `pngquant`）で `Support/AppIcon.icns` を作り直してコミットしてください。

## DMG で配布する

最新版のダウンロード: [Karuta.dmg](https://github.com/trkw/karuta/releases/latest/download/Karuta.dmg)（[リリース一覧](https://github.com/trkw/karuta/releases)）

```sh
make dmg   # build/Karuta-<バージョン>.dmg を作成
```

リリースは次のどれかで作られます。DMG は GitHub Release に添付されます。

- **バージョンを上げて main にマージする：** `Support/Info.plist` の `CFBundleShortVersionString` を上げると、そのバージョンのリリースがまだなければ自動で作られます。
- **タグを push する：** `git tag v0.2.0 && git push origin v0.2.0`
- **Actions タブから実行する：** 「Release」ワークフローの「Run workflow」にバージョンを入れて実行します。

PR や main への push でも DMG がビルドされ、Actions の実行結果からダウンロードできます（7 日間保存）。

### DMG から入れるとき

Apple の公証を受けていないため、ダウンロードした DMG のアプリは初回起動時に Gatekeeper にブロックされます。Applications にコピーしたあと、次のどちらかで開いてください。

- 「システム設定」>「プライバシーとセキュリティ」に出る「このまま開く」を押す
- ターミナルで `xattr -dr com.apple.quarantine /Applications/Karuta.app` を実行する

警告なしで配布するには、Apple Developer Program（年 99 USD）の Developer ID 署名と公証が必要です。
