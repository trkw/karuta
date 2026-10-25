# Karuta

個人用の軽量スクリーンショットアプリ（macOS 14 以上）。CleanShot X を参考に、必要な機能だけを小さく作っています。

## 方針

- メニューバー常駐のみ（Dock アイコンなし）
- AppKit と ScreenCaptureKit だけで作り、外部ライブラリは使わない
- ウィンドウは使うときだけ作り、撮影した画像はすぐ解放する

## 機能（v0.1）

| ショートカット | 動作 |
| --- | --- |
| ⌥⇧4 | 範囲を撮影（Space でウィンドウ選択に切り替え、Esc でキャンセル） |
| ⌥⇧5 | ウィンドウを撮影（クリックしたウィンドウ） |
| ⌥⇧3 | マウスがある画面の全画面を撮影 |

撮影後は左下にクイックオーバーレイが出ます。「コピー」でクリップボードへ、「保存」でデスクトップへ保存します。サムネイルを Finder や他のアプリへドラッグすることもできます。6 秒ほどで自動で閉じます（ポインタを乗せている間は閉じません）。

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

## DMG で配布する

```sh
make dmg   # build/Karuta-<バージョン>.dmg を作成
```

`v0.2.0` のようなタグを push すると、GitHub Actions が DMG をビルドして GitHub Release に添付します。バージョンはタグから付けられます。

```sh
git tag v0.2.0 && git push origin v0.2.0
```

タグを打つ代わりに、GitHub の Actions タブで「Release」ワークフローを選び、「Run workflow」にバージョンを入れて実行しても同じリリースが作られます。

PR や main への push でも DMG がビルドされ、Actions の実行結果からダウンロードできます（7 日間保存）。

### DMG から入れるとき

Apple の公証を受けていないため、ダウンロードした DMG のアプリは初回起動時に Gatekeeper にブロックされます。Applications にコピーしたあと、次のどちらかで開いてください。

- 「システム設定」>「プライバシーとセキュリティ」に出る「このまま開く」を押す
- ターミナルで `xattr -dr com.apple.quarantine /Applications/Karuta.app` を実行する

警告なしで配布するには、Apple Developer Program（年 99 USD）の Developer ID 署名と公証が必要です。
