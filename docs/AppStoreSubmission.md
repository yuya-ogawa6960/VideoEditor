# Video Mania App Store 申請メモ

## アプリ情報(App Store Connect →「App 情報」)
- 名前: Video Mania
- サブタイトル(30 字以内): AI で簡単、本格動画編集
- カテゴリ: 写真/ビデオ(サブ: エンターテインメント)
- 年齢制限: 4+(質問はすべて「なし」。広告あり)
- プライバシーポリシー URL: https://videomania-api.yuya-ogawa0906.workers.dev/privacy
- サポート URL: https://videomania-api.yuya-ogawa0906.workers.dev/support
- 著作権: 2026 Yuya Ogawa
- 価格: 無料

## 説明文(日本語)
Video Mania は、iPhone だけで SNS 向けの縦動画や本格的な動画を作れる動画編集アプリです。AI がカット・キャプション・色味まで手伝うので、はじめてでも簡単。慣れた人はプロ向けの用語と操作で、じっくり編集できます。

■ AI におまかせ
・おまかせ編集: 見どころを探して、話の途中で切らずに自動でつなぎます
・キャプションの自動作成: 端末内(無料)/クラウド(高精度)から選べる文字起こし、翻訳にも対応
・無音カット: 話していない間をまとめて詰めて、テンポよく
・中だるみチェック: 景色・表情・会話のテンポを見て、間延びする所を色で教えます
・AI 読み上げ: 端末の声・自分の声(パーソナルボイス)・クラウドの多彩な声
・顔の自動モザイク、オートリフレーム、自動補正、スピーチを強調(雑音除去)

■ 本格編集
・スプリット、リップル削除、速度・タイムリマップ、逆再生、フレーム保持
・31 種類のビデオトランジション、クリップ・テキストのアニメーション
・カラー補正、HSL、LUT 読み込み、カラーマッチ、カラースコープ
・テキスト・キャプション・ステッカー・手書き、キーフレーム、マスク、トラッキング
・オーバーレイ(B ロール・ワイプ)、マルチカメラ、J/L カット、ボイスオーバー
・1,900 種類以上の Google Fonts、ロゴ・透かしの保存

■ 書き出し
・最大 4K / 60fps。縦 9:16 と横 16:9 をまとめて作る SNS パック
・GIF・音声だけ・キャプションファイル・チャプター一覧
・iOS 26 以降はロック中も書き出し・文字起こしが続きます

■ ポイント
Apple でサインインすると、自分の API キーがなくてもポイントでクラウド AI を使えます(はじめて 100 ポイント、毎日 10 ポイント、広告を見て 1 日 3 回まで追加)。ポイントは無料で、購入はできません。

## キーワード(100 字以内・カンマ区切り)
動画編集,キャプション,字幕,テロップ,カット,AI,自動編集,vlog,ショート,リール,縦動画,文字起こし,トランジション,エフェクト,モザイク,無音カット
(他社のアプリ名・商標は入れない。TikTok・YouTube・Premiere などはキーワードにも説明文にも書かない)

## 新機能(このバージョン)
1.12.92(1.12.70 のあと、Osmo Pocket の実験機能は入れない):

- マルチカメラを作り直しました。全部のアングルを並べて同時に再生し、使いたい映像をタップするだけで切り替えられます。
- 別のカメラの動画を、音で自動的に合わせます。長い収録や、機器どうしの時計のずれにも対応しました。
- マルチカメラの切り替えを、タイムラインの V2・V3 のトラックとして表示します。カットごとにアングルを変えたり、カットを消したりできます。
- カラープリセットを 16 種類増やしました(全 29 種類)。今までの色のプリセットも、はっきり効くようにしました。強さを動かすと、その場でプレビューに反映されます。
- BGM を新しい 160 曲(ダンス 10 曲を含む)に作り直しました。試聴して、気に入った曲をダウンロードして使えます。
- 効果音を約 180 種に増やしました。
- 色の調整で、プレビューを長押しすると元の色と比べられます。
- キャプションを一覧で直せるようになりました。
- カメラで撮るときの台本の表示と画質を改善しました。
- プロジェクト一覧を 16:9 の表示にしました。
- 画面の向きが戻らない、タップが効かないことがある、などの不具合を直しました。

英語(en):

- Rebuilt Multi-Camera: play every angle side by side and tap the one you want to switch to.
- Angles from other cameras now sync automatically by sound, including long recordings and clock drift between devices.
- Multi-camera switches now appear on the timeline as V2/V3 tracks, where you can change the angle of a cut or delete it.
- Added 16 color presets (29 in total) and made the existing color presets clearly visible. Changing the strength updates the preview right away.
- Rebuilt the music library with 160 new tracks, including 10 dance tracks. Preview any track, then download the ones you like.
- Added about 180 sound effects.
- Press and hold the preview while adjusting color to compare with the original.
- Edit captions in a list.
- Improved the script display and picture quality when recording with the camera.
- The project list now shows 16:9 thumbnails.
- Fixed issues such as the screen not rotating back and taps sometimes not responding.

## App Review への情報(App Review Information → メモ)
- サインインは任意です。サインインしなくても、編集・書き出し・端末内 AI はすべて使えます。
- サインイン(Apple でサインイン)するとポイントでクラウド AI(OpenAI・Google の読み上げ)を使えます。確認する場合は、プロジェクト一覧の左上の星のアイコンからサインインしてください。
- アカウントの削除は、同じ画面の「アカウントを削除」から行えます。
- アプリ内課金は、自動更新サブスクリプションの Standard(月額 490 円)と Pro(月額 1,490 円)です。ポイントだけを買うことはできません(無料の配布・リワード広告のほか、有料プランに毎月のポイントが付きます)。
- 広告は Google AdMob です。ヨーロッパなどでは UMP の同意画面が出ます。広告は編集画面には出しません。
- 利用者が自分の OpenAI API キーを入力して使うこともできます(任意。アプリ内で何かを売る機能ではありません)。
- 「広告を見てポイント」は、広告を最後まで見ると 10 ポイント増えます(1 日 3 回まで)。審査環境ではテスト用の広告が出ます。
- AI(台本・翻訳・読み上げ)の文章は送信前に OpenAI の moderation で確認し、不適切なものは生成しません。生成結果には「問題を報告」があり、サポートページの問い合わせフォームに届きます。
- 顔のモザイクと人物優先の切り抜きは、Vision の矩形検出だけを使います。個人の識別や保存はしません。
- 端末内の文字起こし(Whisper)は、初回に 150〜630MB のモデルをダウンロードします(確認ダイアログあり)。
- 「ロック中も書き出しが続く」機能は iOS 26 以降の BGContinuedProcessingTask を使います。UIBackgroundModes の processing はそのためだけで、ほかのバックグラウンド処理はありません。
- Google フォトからの取り込みは、このビルドでは無効です(選択肢が出ません)。
- 使い方の統計(匿名)は初回起動時に送信するか聞き、サーバーでは 90 日で削除します。設定でいつでも変えられます。
- サポート URL に問い合わせフォームがあります(質問・不具合・AI の報告・広告の報告・データ削除の依頼)。
- デモ用のアカウントは不要です。

## スクリーンショット(6.9 インチ 1320×2868 と 6.5 インチ 1284×2778 が必要)
1. 編集画面(タイムラインとプレビュー)
2. おまかせ編集のスタイル選択
3. 字幕の自動作成(テンプレート)
4. トランジションの見本一覧
5. 中だるみチェック(緑・黄・赤)
6. 書き出し画面

## App のプライバシー(App Store Connect →「App のプライバシー」)
- データを収集する: はい
- ユーザ ID(Apple でサインインの識別子): App の機能、ユーザに関連付けられる、トラッキングなし
- オーディオデータ(クラウド文字起こしで OpenAI に送信): App の機能、関連付けなし
- その他のユーザコンテンツ(字幕・台本の文章を OpenAI に送信): App の機能、関連付けなし
- 広告データ・デバイス ID・おおよその位置・製品の操作(Google AdMob): サードパーティ広告、トラッキングあり(ATT で許可された場合)
- デバイス ID(Meta の SDK。広告識別子と、SDK が端末ごとに作るランダムな ID): サードパーティ広告・アナリティクス・App の機能、ユーザに関連付けられる、トラッキングあり(ATT で許可された場合)。App Store Connect には SDK ごとの欄がないので、AdMob と同じ「デバイス ID」の回答を「関連付けあり」に変えて目的を足す
- 購入履歴(Meta に送る初めての購入の金額・通貨と、毎月のポイントのためにサーバーに保存する購入の番号・商品・期限): App の機能・デベロッパの広告またはマーケティング・サードパーティ広告・アナリティクス、ユーザに関連付けられる、トラッキングあり
- 製品の操作(Meta の SDK。アプリを開いたこと・初回のインストールの通知・利用時間): デベロッパの広告またはマーケティング・サードパーティ広告・アナリティクス、ユーザに関連付けられる、トラッキングあり(ATT で許可された場合)。App Store Connect には SDK ごとの欄がないので、AdMob と自前の統計の分も含めて「製品の操作」の回答はこの内容にする
- その他のデータ(Meta の SDK): アナリティクス、関連付けなし、トラッキングなし
- 診断(クラッシュ・パフォーマンス、AdMob): 関連付けなし(クラッシュデータの目的に、Meta の SDK の分の App の機能も足す)
- 製品の操作(使い方の統計、自前サーバー): 分析、関連付けなし、トラッキングなし

## 公開前にサーバー側でやること
- AdMob のリワード広告ユニットの「サーバーサイド認証」に https://videomania-api.yuya-ogawa0906.workers.dev/v1/ads/ssv を登録
- wrangler.toml の ALLOW_CLIENT_AD_CLAIM は "0"(済)。
- TestFlight・App Review のテスト広告のポイントは、アプリが送る Apple 署名の AppTransaction(receiptType が Sandbox)を
  サーバーが確かめて付ける(server/src/appTransaction.js)。証明が取れない端末のために、GitHub の secret `TEST_AD_USERS` の
  アカウント ID(アプリの 設定 → バージョンを 5 回タップ → サポート用の情報 → アカウント ID)でも付く

## 「共有」から受け取る拡張機能の設定(Apple Developer、最初に 1 回)

「共有」→「Video Mania」で受け取る拡張機能(ShareExtension)は、アプリと共有フォルダ(App Group)を使います。
App Group と拡張機能の App ID が Apple Developer に無いと、書き出し(クラウド署名)が
`Authentication failed` / `No profiles for 'com.yuyaogawa6960.videomania.share' were found` で止まります(1.12.43 で発生)。
そのため、GitHub のリポジトリ変数 `SHARE_EXTENSION` が `on` でないあいだは、CI が project.yml の
`# >>> share-extension` 〜 `# <<< share-extension` のあいだ(拡張機能・App Group の権限)を消して作ります。
その版ではアプリ内の「共有から送れます」の案内も出しません(`AppGroup.isAvailable`)。

入れるときは [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) で次の 3 つを設定します。

1. Identifiers →「+」→ **App Groups** → `group.com.yuyaogawa6960.videomania` を登録する
2. App ID `com.yuyaogawa6960.videomania` を開き、**App Groups** をオン →「Configure」で上のグループにチェック → Save(Sign in with Apple はオンのまま)
3. Identifiers →「+」→ **App IDs** → App → Bundle ID `com.yuyaogawa6960.videomania.share` で登録し、**App Groups** をオンにして同じグループにチェック

そのあと GitHub の Settings → Secrets and variables → Actions → **Variables** で `SHARE_EXTENSION` を `on` にして、
もう一度 push(またはワークフローを再実行)します。プロファイルは書き出しのときに自動で作り直されます。
それでも `Authentication failed` が出るときは、App Store Connect API キーの役割を Admin にしてください。

## Google フォトから直接取り込む機能

設定と Google の審査の手順は `docs/GooglePhotosSetup.md`。Google の審査が通るまでは `project.yml` の `GOOGLE_OAUTH_CLIENT_ID` を空のまま出す(空のあいだは「Google フォト」の選択肢が出ない)。
