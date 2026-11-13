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
次の提出(1.12.109。App Store に出ている 1.12.99 のあとの変更をまとめたもの)。4 つの言語の欄に、それぞれ貼り付ける。

日本語(ja):

- トランジションで言葉が消えなくなりました。切り替わりの前後の映像を使うので、話の途中でつないでも声が途切れません。
- AI のツールを、全体にも、選んだクリップだけにも使えるようになりました(おまかせ編集・無音カット・言いよどみカット・文字起こし編集・オートパンチイン・スピーチを強調・オートリフレーム・字幕を翻訳・吹き替え)。
- プロジェクト一覧に「台本から作る」を追加しました。AI で台本を作って、ナレーションやキャプションにしたり、カメラで読みながら撮ったりできます。
- 効果音を約 290 種類に作り直しました。16 のカテゴリから選べて、名前で探せます。
- V1 と V2 の動画を音で合わせて、上下・左右に並べられるようになりました。V2 の中の映像は、顔を真ん中にしたり、顔を追いかけたりできます。
- 画面の端に置くタイトル 18 種類、チャプターのラベル、【】で囲んだ文字の色分けなど、テキストのテンプレートを増やしました。方眼紙のスライド背景も追加しました。
- 文字起こしで、「(音楽)」などの注釈や、音楽・雑音の所の誤認識を取り除くようにしました。軽いモデルで日本語を文字起こししたときは、精度の高いモデルで作り直す案内を出します。
- iPhone Duo では、ツールを右の列に置いて、プレビューを大きく表示するようにしました。
- Standard プランでは全画面の広告が出なくなりました(Pro は広告なし)。
- 被写体フラッシュのプレビュー、ツールバーの表示、Apple Intelligence が使えないときの案内など、多くの点を直しました。

英語(en):

- Transitions no longer cut off speech. They use footage from just before and after the cut, so words aren't lost even when you cut mid-sentence.
- Use the AI tools on the whole project or on just the selected clip (Auto Edit, Silence Cut, Filler Cut, Transcript Edit, Auto Punch-In, Enhance Speech, Auto Reframe, Translate Captions and Dubbing).
- New "Start from a Script" on the project list. Write a script with AI, then turn it into narration or captions, or read it on the teleprompter while recording.
- Rebuilt the sound effects: about 290 sounds in 16 categories, with search.
- Sync a V1 and a V2 video by sound and show them stacked or side by side. Keep a face centered in V2, or follow it.
- More text templates: 18 edge titles, chapter labels, and color accents for text in 【】. Added a grid-paper slide background.
- Transcription now removes notes like "(music)" and misrecognitions over music or noise. When the lightest model is used for Japanese, the app suggests redoing it with a more accurate model.
- On iPhone Duo, the tools sit in the right column so the preview is larger.
- No full-screen ads on the Standard plan (no ads on Pro).
- Many fixes, including the subject flash preview, toolbar layout, and guidance when Apple Intelligence isn't available.

スペイン語(es):

- Las transiciones ya no cortan lo que se dice. Usan imágenes de justo antes y después del corte, así que no se pierden palabras aunque cortes a mitad de una frase.
- Usa las herramientas de IA en todo el proyecto o solo en el clip seleccionado (edición automática, corte de silencios, corte de muletillas, edición por transcripción, zoom automático, realce de voz, reencuadre automático, traducción de subtítulos y doblaje).
- Nuevo «Empezar con un guion» en la lista de proyectos. Escribe un guion con IA y conviértelo en narración o subtítulos, o léelo en el teleprompter mientras grabas.
- Efectos de sonido renovados: unos 290 sonidos en 16 categorías, con búsqueda.
- Sincroniza un video V1 y uno V2 por el sonido y muéstralos arriba y abajo o lado a lado. Mantén una cara centrada en V2 o síguela.
- Más plantillas de texto: 18 títulos en los bordes, etiquetas de capítulo y color para el texto entre 【】. Nuevo fondo de diapositiva cuadriculado.
- La transcripción ahora quita notas como «(música)» y errores de reconocimiento sobre música o ruido. Si se usa el modelo más ligero para japonés, la app sugiere rehacerla con un modelo más preciso.
- En iPhone Duo, las herramientas se colocan en la columna derecha para que la vista previa sea más grande.
- Sin anuncios a pantalla completa en el plan Standard (sin anuncios en Pro).
- Muchas correcciones, como la vista previa del destello del sujeto, el diseño de la barra de herramientas y los avisos cuando Apple Intelligence no está disponible.

ポルトガル語・ブラジル(pt-BR):

- As transições não cortam mais a fala. Elas usam imagens de logo antes e depois do corte, então nenhuma palavra se perde, mesmo cortando no meio de uma frase.
- Use as ferramentas de IA no projeto inteiro ou só no clipe selecionado (edição automática, corte de silêncios, corte de vícios de linguagem, edição pela transcrição, zoom automático, realce de fala, reenquadramento automático, tradução de legendas e dublagem).
- Novo "Começar por um roteiro" na lista de projetos. Crie um roteiro com IA e transforme em narração ou legendas, ou leia no teleprompter enquanto grava.
- Efeitos sonoros renovados: cerca de 290 sons em 16 categorias, com busca.
- Sincronize um vídeo V1 e um V2 pelo som e mostre um acima do outro ou lado a lado. Mantenha um rosto centralizado no V2 ou siga-o.
- Mais modelos de texto: 18 títulos nas bordas, rótulos de capítulo e cor para o texto entre 【】. Novo fundo de slide quadriculado.
- A transcrição agora remove anotações como "(música)" e erros de reconhecimento sobre música ou ruído. Quando o modelo mais leve é usado para japonês, o app sugere refazer com um modelo mais preciso.
- No iPhone Duo, as ferramentas ficam na coluna direita para a prévia ficar maior.
- Sem anúncios em tela cheia no plano Standard (sem anúncios no Pro).
- Muitas correções, como a prévia do destaque do sujeito, o layout da barra de ferramentas e os avisos quando o Apple Intelligence não está disponível.

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
