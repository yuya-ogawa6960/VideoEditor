# Google フォトから取り込む機能の準備(Google Photos Picker API)

アプリの「追加 → Google フォト」は、Google 公式の **Google Photos Picker API** を使います。
(2025 年 3 月から、Library API では利用者のライブラリ全体を読めなくなりました。Picker API は「利用者が Google フォトの画面で選んだものだけ」をアプリが受け取る仕組みです。)

アプリ側のコードはできています。必要なのは、Google Cloud で **OAuth クライアント ID** を作って `project.yml` に入れることだけです。
クライアント ID が空のあいだは、アプリに「Google フォト」の項目は出ません(ほかの取り込み方法はそのまま使えます)。

- 関係するファイル: `Sources/Engine/GoogleOAuth.swift`(ログイン)、`Sources/Engine/GooglePhotosPicker.swift`(選択・ダウンロード)、`Sources/Views/GooglePhotosImportView.swift`(画面)
- プライバシーポリシー: https://videomania-api.yuya-ogawa0906.workers.dev/privacy (「6. Google フォトからの取り込み」を追加済み)

---

## 1. Google Cloud のプロジェクトを作る

1. https://console.cloud.google.com/ を開き、アプリの持ち主の Google アカウントでログイン
2. 上のプロジェクト名 →「新しいプロジェクト」→ 名前 `Video Mania` →「作成」
3. 作ったプロジェクトが選ばれていることを確認する

## 2. Photos Picker API を有効にする

1. 左のメニュー「API とサービス」→「ライブラリ」
2. `Photos Picker API` を検索 →「有効にする」
   - 似た名前の「Photos Library API」ではありません。**Picker** の方です

## 3. OAuth の同意画面(Google Auth Platform)を設定する

左のメニュー「Google Auth Platform」(古い画面では「OAuth 同意画面」)→「開始」。

### 3-1. アプリ情報・対象
- アプリ名: `Video Mania`
- ユーザー サポートメール: 自分のメールアドレス
- 対象(Audience): **外部(External)**
- 連絡先情報: 自分のメールアドレス(Google からの審査の連絡はここに届きます)
- ポリシーに同意 →「作成」

### 3-2. ブランディング
- アプリのロゴ: 120×120 px の正方形の PNG(1 MB 以下)。App Store のアイコン(`Sources/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`)を縮小したもの
  - ロゴを入れると「ブランドの確認」が必要になります(2〜3 営業日)
- アプリのホームページ: アプリの説明があり、プライバシーポリシーへのリンクがあるページ
  - 今は `https://videomania-api.yuya-ogawa0906.workers.dev/support` が使えます(プライバシーポリシーへのリンクあり)
  - 審査では「アプリが何をするか」が書かれたホームページを求められることが多いので、必要なら Claude に「サーバーの / をアプリの紹介ページにして」と頼んでください(今の `/` は JSON を返すだけです)
- プライバシーポリシーのリンク: `https://videomania-api.yuya-ogawa0906.workers.dev/privacy`
- 承認済みドメイン: `yuya-ogawa0906.workers.dev`
  - `workers.dev` は「公開サフィックス」なので、承認済みドメインは `yuya-ogawa0906.workers.dev` になります
  - **テスト中(3-4)のあいだは、これで十分です**(ドメインの確認は求められません。ロゴを入れなければブランドの確認も始まりません)
  - **公開して審査(6.)を受けるときは、承認済みドメインを Google Search Console で自分のものだと確認する必要があります。**
    `yuya-ogawa0906.workers.dev` は DNS のレコードを追加できず、そのアドレス自体にページを置くこともできないので、実際には確認できません。
    そのため審査の前に **独自ドメイン**(例: `videomania.app`。Cloudflare Registrar で年 1,500〜3,000 円ほど)を取り、Cloudflare で Workers の「カスタムドメイン」に割り当ててください。
    そのあと Search Console の「ドメイン」プロパティで、表示される TXT レコードを Cloudflare の DNS に追加すれば確認できます。
    独自ドメインにしたら、Claude に「サーバーの URL を独自ドメインに変えて」と頼んでください(アプリの `VM_SERVER_URL`、App Store Connect のプライバシーポリシー URL もまとめて変えます)
- デベロッパーの連絡先: 自分のメールアドレス

### 3-3. データアクセス(スコープ)
1. 「スコープを追加または削除」
2. 一覧の下の「スコープの手動追加」に次を貼り付けて「表に追加」→「更新」→「保存」

   ```
   https://www.googleapis.com/auth/photospicker.mediaitems.readonly
   ```
3. 追加するのは **この 1 つだけ** です(メールアドレスやプロフィールのスコープも要りません)
   - 表で「機密性の高いスコープ」に分類されているはずです(公開すると審査が必要。セキュリティ評価(CASA)が要る「制限付き」ではありません)

### 3-4. 対象(テストユーザー)
- 公開ステータスが「テスト中」のあいだは、ここに追加した Google アカウント(**100 人まで**)だけがログインできます
- 「Add users」で自分と、TestFlight で試してもらう人の Gmail アドレスを追加
- 注意: テスト中は、ログインの有効期限が **7 日** です。7 日たつとアプリが「もう一度ログインしてください」と出します(アプリはそのように作ってあります)。公開後はこの制限はなくなります
- テスト中・未確認のあいだは、ログイン時に「このアプリは Google で確認されていません」と出ます。「詳細」→「Video Mania(安全ではないページ)に移動」で進めます

## 4. OAuth クライアント ID(iOS)を作る

1. 「Google Auth Platform」→「クライアント」→「クライアントを作成」
2. アプリケーションの種類: **iOS**
3. 名前: `Video Mania iOS`
4. バンドル ID: `com.yuyaogawa6960.videomania`
5. App Store ID・チーム ID: 分かれば入れる(チーム ID は `779F5Z8KQX`。なくても動きます)
6. 「作成」→ 表示される **クライアント ID**(`123456789012-xxxxxxxx.apps.googleusercontent.com` の形)をコピー
   - iOS のクライアントにはクライアントシークレットはありません(アプリは PKCE で安全にログインします)
   - クライアント ID はアプリに埋め込まれる公開の値なので、`project.yml` に書いて GitHub に push して大丈夫です

## 5. アプリに入れる

`project.yml` の `targets → VideoEditor → settings → base` にある `GOOGLE_OAUTH_CLIENT_ID` に、コピーした ID を入れます。

```yaml
    settings:
      base:
        ...
        GOOGLE_OAUTH_CLIENT_ID: "123456789012-xxxxxxxx.apps.googleusercontent.com"
```

- Info.plist の `GoogleOAuthClientID` は `$(GOOGLE_OAUTH_CLIENT_ID)` になっているので、ほかに変えるところはありません
- ログインから戻ってくる URL(`com.googleusercontent.apps.<ID の前半>:/oauth2redirect`)はアプリが自動で作ります。URL スキームの登録も要りません
- main に push すると TestFlight にビルドが届きます

### 試し方
1. TestFlight のビルドで、編集画面の「追加」→「Google フォト」
2. 「Google でログイン」→ テストユーザーに追加したアカウントでログイン → 許可
3. 「Google フォトを開いて選ぶ」→ Google フォトのアプリ(なければ Safari)で写真・動画を選んで「完了」
4. Video Mania に戻ると自動でダウンロードが始まり、タイムラインに追加されます

うまくいかないとき:
- 「アクセスをブロック: このアプリはテスト中です」→ そのアカウントをテストユーザーに追加する
- 「Google フォトにアクセスできませんでした(…Photos Picker API has not been used…)」→ 2. の API が有効になっていない
- 「redirect_uri_mismatch」「invalid_client」→ クライアントの種類が iOS か、バンドル ID が合っているか、ID を正しく貼ったか

---

## 6. 公開と Google の審査(確認)

「テスト中」のままでは 100 人のテストユーザーしか使えません。App Store で誰でも使えるようにするには、公開して **確認(verification)** を受けます。

### おすすめの順番
1. 3. の設定を全部終える(独自ドメインに移し、Search Console でドメインを確認し、ロゴ・ホームページ・プライバシーポリシーをそのドメインの URL にする)
2. 「対象」→ 公開ステータスを「アプリを公開」で **本番環境** にする
   - 審査が終わるまでは「確認されていません」の画面が出て、使える人も 100 人までです
3. 「確認センター」(Verification Center)→「確認のために送信」
4. App Store 版に出すのは、審査が通ってから(それまでは `GOOGLE_OAUTH_CLIENT_ID` を空にしたビルドで申請すれば、「Google フォト」の項目は出ません)

### Google が確認すること
- ブランド: アプリ名・ロゴ・ホームページ・プライバシーポリシーが、確認済みのドメインにあり、内容が一致しているか
- プライバシーポリシー: Google のデータを何に使い、どう扱うか。**Limited Use(限定的な使用)の宣言** があるか
  - 次の文が /privacy に英語と日本語で入っています:
    > Video Mania's use and transfer to any other app of information received from Google APIs will adhere to Google API Services User Data Policy, including the Limited Use requirements.
  - Google が求める決まった文(「to any other app」も含めてこのとおり)なので、言い回しを変えないでください
- スコープ: `photospicker.mediaitems.readonly` が本当に必要か、最小限か(説明文とデモ動画で確認)
- デモ動画: 実際のアプリで、同意画面とスコープの使われ方が見えるか

### スコープの説明(「スコープの使用方法」に英語で書く例)
```
Video Mania is an on-device video editor for iPhone. The photospicker.mediaitems.readonly scope is used only
when the user taps "Add > Google Photos" in the editor. The app creates a Google Photos Picker session, the user
selects photos and videos in the Google Photos picker, and the app downloads only those selected items directly
to the device so they can be added to the user's video timeline. The app never reads the rest of the library,
does not send the media to our servers or to third parties, and stores the OAuth tokens only in the iOS Keychain.
The Picker API is the minimum scope for this feature; no other Google scopes are requested.
```

### デモ動画の台本(YouTube に「限定公開」で上げてリンクを貼る)
iPhone の画面収録(コントロールセンター → 画面収録)で撮ります。2〜3 分で十分です。説明は英語の字幕かナレーションがあると通りやすいです。

1. (最初に)Google Cloud の「クライアント」画面を映し、使っている **クライアント ID** を見せる
   - Google は「同意画面のアドレスバーに client_id が見えること」を求めることがあります。iPhone のログイン画面ではアドレスバーの全体が見えないので、ここでクライアント ID を見せておき、求められたら Mac の Safari で同じログインの URL を開いてアドレスバーを見せた動画を追加します
2. Video Mania を開き、プロジェクトの編集画面 →「追加」→「Google フォト」
3. 説明の画面(選んだものだけを見る・iPhone の中だけで編集する)を見せる
4. 「Google でログイン」→ Google の **同意画面**(アプリ名 Video Mania と「Google フォトの写真と動画のうち、選択したものの表示」などの権限の文)をはっきり映し、「許可」
5. 「Google フォトを開いて選ぶ」→ Google フォトで写真 1 枚と動画 1 本を選んで「完了」
6. Video Mania に戻り、ダウンロードの進み具合 → タイムラインに追加されるところ
7. 追加した写真・動画を少し編集・再生して、「選んだものだけが編集に使われる」ことを見せる
8. 「ログアウト」ボタンと、Google アカウントの「サードパーティ製のアプリとサービス」から接続を削除できることを見せる

### よくある質問への答え方
- 「どのデータをどこに保存しますか」→ 選んだ写真・動画は端末内の編集用フォルダにだけ保存。サーバーには送らない。トークンは iOS のキーチェーンだけ
- 「第三者に渡しますか」→ 渡さない。ただし利用者が自分で「クラウド AI の文字起こし」を選んだときだけ、その動画の音声を OpenAI に送る(プライバシーポリシーの 2. に記載。Google から受け取ったデータを AI の学習には使わない)
- 「なぜこのスコープが必要ですか」→ Picker API で利用者が選んだものを取り込むのに必要な唯一のスコープ。ライブラリ全体を読むスコープは使っていない
- 返信は Google から届いたメールのスレッドに、そのまま返信します(新しいメールにしない)

### かかる時間の目安
- ブランドの確認: 2〜3 営業日
- 機密性の高いスコープの確認: 数日〜数週間(指摘があってやり取りすると延びます)
- 指摘が来たら、直してから同じメールに返信 → 再確認

### App Store の審査について
- Google のログインは「Google フォトから写真を取り込む」ためだけで、アプリのアカウントではありません(Apple のガイドライン 4.8 の「ログインサービス」には当たりません)
- 申請メモ(`docs/AppStoreSubmission.md` の App Review への情報)に次を足します:
  - 「Google フォトからの取り込みは任意の機能です。編集画面の『追加』→『Google フォト』から、Google のアカウントでログインして、選んだ写真・動画だけを取り込めます。」
- App のプライバシー(栄養ラベル)は変わりません(開発者は Google のデータを集めないため)

---

## 7. 利用者が接続をやめる方法
- アプリ: 「追加」→「Google フォト」の画面の「ログアウト」(端末のトークンを消し、Google 側の許可も取り消します)
- Google アカウント: https://myaccount.google.com/connections (Google アカウント →「セキュリティ」→「サードパーティ製のアプリとサービスへのアクセス」)→「Video Mania」→「Video Mania とのすべての接続を削除」
  - 取り消したあとにアプリで取り込もうとすると、「もう一度ログインしてください」と出ます
