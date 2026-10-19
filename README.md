# 動画エディタ(個人利用向け iPhone アプリ)

SwiftUI + AVFoundation で作った iPhone 用の動画編集アプリです。
Mac が無くても、GitHub(無料)でビルドして Windows から自分の iPhone に入れられます。

## できること

| 機能 | 内容 |
|---|---|
| カット | クリップごとのトリミング、再生位置での分割 |
| 結合 | 複数の動画を並べてつなぐ、並べ替え、複製、削除 |
| 速度変更 | 0.25倍〜4倍(音程は保ったまま) |
| フィルタ | 13種類のプリセット、強さ、明るさ・コントラスト・彩度 |
| 字幕 | 手入力、位置・色・サイズ・背景の指定 |
| 自動文字起こし | 日本語・英語の音声から字幕を自動作成(端末内で処理) |
| 英語翻訳 | 字幕を英語に翻訳(Apple の翻訳機能、端末内で処理) |
| BGM | 「ファイル」アプリの音楽を追加、音量調整、最後にフェードアウト |
| 複数台カメラ切替 | 別アングルの動画を追加、音声で自動同期、再生しながらタップで切替 |
| 書き出し形式 | SNSショート 9:16、YouTube 横 16:9、正方形、4:5、元のまま。720p〜4K |
| 容量チェック | 書き出し前に推定サイズと空き容量を比べ、足りなければ止める |
| バックグラウンド書き出し | iOS 26 以降はホームに戻っても続行(iOS 18〜25 は約30秒まで) |

動作環境は iOS 18 以降です。

---

## 手順1 GitHub でアプリをビルドする(Mac 不要)

1. https://github.com でアカウントを作ります。
2. 右上の「+」→「New repository」で新しいリポジトリを作ります。
   - 名前は例として `VideoEditor`
   - **Public(公開)** を選ぶと、ビルドが無料・無制限になります。Private でも月2,000分の無料枠内なら使えます(macOS は消費が10倍なので実質月200分)。
3. このフォルダの中身を全部アップロードします。
   - 一番簡単なのは「GitHub Desktop」を使う方法です。https://desktop.github.com
   - ブラウザから入れる場合は、リポジトリ画面の「uploading an existing file」にフォルダの中身をドラッグします。
   - `.github` フォルダ(隠しフォルダ)も必ず含めてください。これがビルド設定です。
4. リポジトリの「Actions」タブを開きます。ビルドが自動で始まり、約5〜10分で終わります。
5. 緑のチェックが付いたら、その実行を開き、下の「Artifacts」から `VideoEditor-ipa` をダウンロードします。
   zip を展開すると `VideoEditor.ipa` が入っています。

ビルドが赤い×で失敗したら、失敗したステップのログをコピーして Claude に貼ってください。修正します。

## 手順2 Windows から iPhone に入れる(無料の Apple ID で可)

無料の Apple ID で署名して入れる仕組みです。制約は次の2つです。

- **7日ごとに再署名が必要**です。期限が切れるとアプリが起動しなくなります(データは残ります)。
- 無料の Apple ID では同時に3アプリまでです。

### 方法A Sideloadly(簡単)

1. Apple 公式サイトから iTunes と iCloud を入れます(Microsoft Store 版ではなく、Apple サイトの Windows 版)。
2. https://sideloadly.io から Sideloadly を入れます。
3. iPhone を USB でつなぎ、iPhone 側で「このコンピュータを信頼」を選びます。
4. Sideloadly に `VideoEditor.ipa` をドラッグし、Apple ID を入力して「Start」を押します。
5. iPhone の「設定 → 一般 → VPNとデバイス管理」で自分の Apple ID を「信頼」します。
6. 「設定 → プライバシーとセキュリティ → デベロッパモード」をオンにして再起動します。

7日後は、同じ操作でもう一度入れ直せば延長できます。

### 方法B AltStore(Wi-Fi で自動更新)

1. iTunes と iCloud(Apple サイト版)を入れ、https://altstore.io から AltServer for Windows を入れます。
2. iPhone を USB でつなぎ、タスクトレイの AltServer から「Install AltStore」で iPhone に AltStore を入れます。
3. 方法A の手順5と6と同じく、信頼とデベロッパモードを設定します。
4. `VideoEditor.ipa` を iCloud Drive などで iPhone に送り、AltStore の「My Apps」→「+」で選んで入れます。
5. PC で AltServer を起動したまま同じ Wi-Fi にいれば、AltStore が7日ごとに自動で更新します。

Apple ID を外部ツールに入力することになるので、気になる場合はサブの Apple ID を作って使ってください。

## 手順3(Mac がある場合)Xcode で直接入れる

Mac が使えるなら、こちらの方が修正と確認が速いです。

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open VideoEditor.xcodeproj
```

Xcode の「Signing & Capabilities」で Team に自分の Apple ID(Personal Team)を選び、
Bundle Identifier を `com.自分の名前.videoeditor` など一意な名前に変えて、iPhone を選んで実行します。
このときも7日ごとの再インストールが必要です。

---

## 使い方のメモ

- **自動文字起こし** は初回に音声認識の許可を求めます。長い動画は50秒ごとに区切って処理します。
- **翻訳** は初回に翻訳用の言語データのダウンロードを求められます。ダウンロード後はオフラインで動きます。
- **複数台カメラ** は、クリップの編集画面から「マルチカメラ」を開き、別アングルの動画を追加します。
  「自動同期」で音声のずれを計算し、再生しながらアングルのボタンをタップすると切替点が記録されます。
- **書き出し** は「書き出し」画面で形式を選び、空き容量が足りることを確認してから開始します。
  完了した動画は「写真」に保存するか、共有ボタンで送れます。
- BGM には、Apple Music の曲(著作権保護付き)は使えません。「ファイル」アプリにある mp3 や m4a を使ってください。

## フォルダ構成

| 場所 | 内容 |
|---|---|
| `project.yml` | プロジェクト定義(XcodeGen 用) |
| `.github/workflows/build.yml` | GitHub でのビルド設定 |
| `Sources/Model` | データ構造、動画の読み込み |
| `Sources/Engine` | 合成、フィルタ、字幕描画、書き出し、文字起こし、翻訳、カメラ同期 |
| `Sources/Views` | 画面 |
| `Sources/App` | アプリの起動処理 |
