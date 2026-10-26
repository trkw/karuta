# 署名と公証

配る dmg と中の Karuta.app は、Developer ID で署名して Apple の公証（notarization）を受け、公証の印を両方に留めて（staple）ある。ダウンロードした dmg を開いても「開発元を確認できない」とは出ない。

CI では `scripts/sign-and-notarize.sh` がする。Karuta は外部のパッケージを使わないので、組み立てと署名を同じジョブでする。

- リリース（`release.yml`）と、main への push・このリポジトリのブランチからの PR（`build.yml`）は署名・公証する
- fork からの PR には鍵が渡らないので、ad-hoc 署名の dmg になる
- 鍵が登録されていなければ、警告を出して今までどおり ad-hoc 署名の dmg を作る。リリースの説明にも「このまま開く」の案内を残す
- hardened runtime で署名し、緩める権限（entitlements）は付けない。画面収録は TCC の許可だけで済む。録画でマイクを使うようになったら `com.apple.security.device.audio-input` を足す

## 鍵を用意して登録する（一度だけ）

ほかのアプリ（sokkou など）で同じ証明書と API の鍵を作ってあれば、1〜3 は飛ばして 4 だけをこのリポジトリに対してすればよい。

Apple Developer Program のアカウント保持者（Account Holder）がする。鍵やパスワードはチャットに貼らず、手元のターミナルから GitHub に直接入れる。

### 1. Developer ID Application の証明書を作る

Xcode → Settings… → Accounts → 自分の Apple ID → チーム → Manage Certificates… → 左下の「+」→ **Developer ID Application**。

（Xcode を使わないなら、キーチェーンアクセスで「証明書アシスタント → 認証局に証明書を要求」で CSR を作り、[Certificates](https://developer.apple.com/account/resources/certificates/list) の「+」→ Developer ID Application（G2 Sub-CA）で上げて、できた .cer を開いてキーチェーンに入れる）

### 2. 証明書を .p12 に書き出す

キーチェーンアクセス → ログイン → 自分の証明書 → 「Developer ID Application: 名前 (チームID)」を右クリック → 書き出す → 形式は「個人情報交換 (.p12)」→ パスワードを決める。証明書の左の三角を開くと秘密鍵が下に付いていることを確かめる（付いていなければ、その Mac で作った証明書ではない）。

### 3. 公証に使う App Store Connect API の鍵を作る

[App Store Connect → ユーザとアクセス → 統合 → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) → チームキー → 「+」→ 名前は `karuta notary` など、アクセスは **Developer** → 生成。

- `AuthKey_XXXXXXXXXX.p8` をダウンロードする（1 回しか落とせない）
- 一覧の **キー ID** と、上に出ている **Issuer ID** を控える

（初めてのときは「API へのアクセスをリクエスト」を先に押す）

### 4. GitHub の Secrets に入れる

このリポジトリを手元に持っていれば、[gh](https://cli.github.com/) にログインしてから、リポジトリの中で:

```sh
scripts/set-signing-secrets.sh ~/Desktop/developer-id.p12 ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

.p12 のパスワードと Issuer ID を尋ねられる（どちらも画面には出ない。キー ID はファイル名から取る）。手で入れるなら（ファイルの場所は自分のものにする）:

```sh
repo=trkw/karuta
base64 -i ~/Desktop/developer-id.p12 | gh secret set APPLE_DEVELOPER_ID_P12 -R "$repo"
gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD -R "$repo"           # 2 で決めたパスワードを聞かれる
gh secret set APPLE_NOTARY_KEY -R "$repo" < ~/Downloads/AuthKey_XXXXXXXXXX.p8
gh secret set APPLE_NOTARY_KEY_ID -R "$repo"                       # キー ID を聞かれる
gh secret set APPLE_NOTARY_ISSUER_ID -R "$repo"                    # Issuer ID を聞かれる
gh secret list -R "$repo"
```

ブラウザからなら、リポジトリの Settings → Secrets and variables → Actions → New repository secret で同じ 5 つを作る（`APPLE_DEVELOPER_ID_P12` には `base64 -i developer-id.p12 | pbcopy` で写したものを貼る）。

入れ終えたら .p12 と .p8 は手元の安全な場所（パスワード管理など）に移し、デスクトップやダウンロードからは消す。

### 5. 確かめる

PR の CI を動かし直すか main に入れると、「Build DMG」ステップの要約に「署名: Developer ID Application: …、公証済み・ステープル済み」と出る。手元では:

```sh
spctl --assess --type open --context context:primary-signature -vv Karuta-<バージョン>.dmg   # source=Notarized Developer ID
xcrun stapler validate Karuta-<バージョン>.dmg
```

## リポジトリを作り直したとき

Secrets はリポジトリについているので、新しいリポジトリに 4 をもう一度する（`repo=` を変えるだけ）。証明書と API の鍵は作り直さなくてよい。

## 鍵が漏れたかもしれないとき

- API の鍵: App Store Connect で取り消して作り直し、`APPLE_NOTARY_KEY*` を入れ直す
- 証明書: [Certificates](https://developer.apple.com/account/resources/certificates/list) で取り消すか Apple に連絡する（取り消すと、その証明書で署名した配布済みの版も開けなくなることがある）
