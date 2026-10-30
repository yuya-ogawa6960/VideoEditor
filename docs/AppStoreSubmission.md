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
はじめてのリリースです。

## App Review への情報(App Review Information → メモ)
- サインインは任意です。サインインしなくても、編集・書き出し・端末内 AI はすべて使えます。
- サインイン(Apple でサインイン)するとポイントでクラウド AI(OpenAI・Google の読み上げ)を使えます。確認する場合は、プロジェクト一覧の左上の星のアイコンからサインインしてください。
- アカウントの削除は、同じ画面の「アカウントを削除」から行えます。
- ポイントは購入できません(無料で配布・リワード広告で付与)。アプリ内課金はありません。
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
- 診断(クラッシュ・パフォーマンス、AdMob): 関連付けなし
- 製品の操作(使い方の統計、自前サーバー): 分析、関連付けなし、トラッキングなし

## 公開前にサーバー側でやること
- AdMob のリワード広告ユニットの「サーバーサイド認証」に https://videomania-api.yuya-ogawa0906.workers.dev/v1/ads/ssv を登録
- wrangler.toml の ALLOW_CLIENT_AD_CLAIM は "0"(済)。
- TestFlight・Xcode のテスト広告のポイントは、「アプリが送る Apple 署名の AppTransaction(environment が Sandbox / Xcode)を
  サーバーが確かめられる」かつ「アカウント ID が GitHub の secret `TEST_AD_USERS` に入っている」ときだけ付く
  (server/src/appTransaction.js、index.js の adClaim)。どちらか一方では付かない。
  アカウント ID は、アプリの 設定 → バージョンを 5 回タップ → サポート用の情報 → アカウント ID。
  断った回は events(ad_claim_rejected)に残り、/stats の「クラッシュ・固まり・カメラの記録」で見られる。
  1 アカウント 1 日 10 回を超える呼び出しは 429 で断る。App Review の審査員はこの条件に入らないので、
  テスト広告を見てもポイントは付かない(「ポイントの反映を確認中です」と出る)

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
