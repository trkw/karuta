# リファクタリングの棚卸し

振る舞いを変えずに構造を直す候補。進め方は、先に確認 (`make test` の karuta-check) で今の動きを押さえてから直し、1 件 1 PR にする。保存の形式や撮影・保存の仕様の根幹に触れるものは、ここでは扱わず判断に回す。

状態は 未着手 / 実施済み (PR) / 見送り (理由)。

| ID | 内容 | 効果 | リスク | 規模 | 状態 |
|---|---|---|---|---|---|
| K1 | ファイル名のテンプレートと ` (2)` の付け方を、AppKit に頼らない `KarutaCore` に移して確認を付ける | 中 | 低 | S | 実施済み (#40) |
| K2 | エディタの「Save as…」(`Editor.saveAs`、シート) が `Exporter.saveAs` (モーダル) と同じ処理を別に持っている。パネルの組み立てと書き出しを 1 か所にまとめる | 中 | 低 | S | 実施済み (#48) |
| K3 | 一時フォルダ (`Karuta/Clipboard`・`Karuta/Recordings`・ドラッグ用の `Karuta`) の場所が `Exporter` の 3 か所にばらばらに書かれている。1 か所にまとめる | 低 | 低 | S | 実施済み (#50) |
| K4 | 保存できなかったときの警告 (`NSAlert(error:)`) が `QuickOverlay`・`Editor`・`Exporter`・`AppDelegate` の 5 か所にある。文言と出し方を 1 つにまとめる | 低 | 低 | S | 実施済み (#51) |
| K5 | 画像の形式 (`Preferences.ImageFormat` の拡張子と UTType) と書き出し (品質 0.9・DPI・Retina の 1x 縮小) を `KarutaCore` に移し、確認を付ける | 中 | 低〜中 | S〜M | 未着手 |
| K6 | 大きいファイルを、中身を変えずに分ける: `SettingsWindow.swift` (約 900 行)・`SelectionOverlay.swift`・`Editor.swift`・`AppDelegate.swift`・`QuickOverlay.swift` (各 700 行前後) | 中 | 低 | M | 一部実施（Editor.swift の部品を EditorControls.swift へ #57、QuickOverlay.swift のボタンと MenuAction を別ファイルへ #58、QuickOverlay.swift の隠したスタックのタブを QuickOverlayStackTab.swift へ #60）|
| K7 | `Preferences` の UserDefaults のキーが文字列で 20 か所ほどに散らばっている。キーを 1 つの型にまとめる (保存されている値と名前は変えない) | 低〜中 | 低 | S | 実施済み (#52) |
| K8 | ファイル名を作るたびに `DateFormatter` を作り直している (`FileNaming.baseName`・`History`)。使い回す | 低 | 低 | S | 実施済み (#47) |
