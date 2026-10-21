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
Video Mania は、iPhone だけでプロのような動画を作れる動画編集アプリです。AI がカット・字幕・色味まで手伝うので、はじめてでも簡単。慣れた人は Premiere Pro と同じ用語・操作感でじっくり編集できます。

■ AI におまかせ
・おまかせ編集: 見どころを探して、話の途中で切らずに自動でつなぎます
・字幕の自動作成: 端末内(無料)/クラウド(高精度)から選べる文字起こし、翻訳にも対応
・中だるみチェック: 景色・表情・会話のテンポを見て、間延びする所を色で教えます
・AI 読み上げ: 端末の声・自分の声(パーソナルボイス)・クラウドの多彩な声
・顔の自動モザイク、オートリフレーム、自動補正、スピーチを強調(雑音除去)

■ 本格編集
・スプリット、リップル削除、速度・タイムリマップ、逆再生、フレーム保持
・31 種類のビデオトランジション、クリップ・テキストのアニメーション
・カラー補正、HSL、LUT 読み込み、カラーマッチ、カラースコープ
・テキスト・字幕・ステッカー・手書き、キーフレーム、マスク、トラッキング
・オーバーレイ(B ロール・ワイプ)、マルチカメラ、J/L カット、ボイスオーバー
・1,900 種類以上の Google Fonts、ロゴ・透かしの保存

■ 書き出し
・4K / HDR / 60fps、縦横同時書き出し、GIF・音声のみ・チャプター一覧
・iOS 26 以降はロック中も書き出し・文字起こしが続きます

■ ポイント
Apple でサインインすると、自分の API キーがなくてもポイントでクラウド AI を使えます(はじめて 100 ポイント、毎日 20 ポイント、広告で追加)。

## キーワード(100 字以内・カンマ区切り)
動画編集,字幕,テロップ,カット,AI,自動編集,vlog,ショート,リール,TikTok,YouTube,文字起こし,トランジション,エフェクト,モザイク

## 新機能(このバージョン)
はじめてのリリースです。

## App Review への情報(App Review Information → メモ)
- サインインは任意です。サインインしなくても、編集・書き出し・端末内 AI はすべて使えます。
- サインイン(Apple でサインイン)するとポイントでクラウド AI(OpenAI)を使えます。確認する場合は「編集画面 → AI → キャプションを作成 → 文字起こしの方式」からサインインしてください。
- アカウントの削除は同じ画面の「アカウントを削除」から行えます。
- ポイントは購入できません(無料で配布・リワード広告で付与)。アプリ内課金はありません。
- 広告は Google AdMob です。ヨーロッパなどでは UMP の同意画面が出ます。
- 利用者が自分の OpenAI API キーを入力して使うこともできます(任意)。
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
- wrangler.toml の ALLOW_CLIENT_AD_CLAIM は "0"(済)。TestFlight のテスト広告だけアプリの申告で付与

## 「共有」から受け取る拡張機能の設定(Apple Developer、最初に 1 回)

「共有」→「Video Mania」で受け取る拡張機能(ShareExtension)は、アプリと共有フォルダ(App Group)を使います。
ビルドの書き出し(クラウド署名)が「App Groups の入ったプロビジョニングプロファイルが必要」などで失敗したら、
[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) で次の 3 つを設定してから、もう一度 push(またはワークフローを再実行)してください。

1. Identifiers →「+」→ **App Groups** → `group.com.yuyaogawa6960.videomania` を登録する
2. App ID `com.yuyaogawa6960.videomania` を開き、**App Groups** をオン →「Configure」で上のグループにチェック → Save(Sign in with Apple はオンのまま)
3. Identifiers →「+」→ **App IDs** → App → Bundle ID `com.yuyaogawa6960.videomania.share` で登録し、**App Groups** をオンにして同じグループにチェック

プロファイルは書き出しのときに自動で作り直されます(App Store Connect API キーの役割が Admin でないと、3 を先に手で登録する必要があります)。

## Google フォトから直接取り込む機能

設定と Google の審査の手順は `docs/GooglePhotosSetup.md`。Google の審査が通るまでは `project.yml` の `GOOGLE_OAUTH_CLIENT_ID` を空のまま出す(空のあいだは「Google フォト」の選択肢が出ない)。
