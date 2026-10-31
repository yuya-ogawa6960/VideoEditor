# DJI Osmo Pocket 4 を Video Mania につなぐ(調査と試作)

> **状態: 試作。実機ではまだ一度も試していません。** CI に Osmo Pocket は無く、この環境では Swift のコンパイルもできませんでした。
> 下の「実機で確かめること」を順に試し、ログ(画面の「ログを共有」)を送ってください。

## 結論

- DJI は Osmo Pocket 向けの SDK を出していません。つなぐ方法は、オープンソースの **OpenPocketCine** が DJI Mimo の通信を観察して突き止めたものだけです。
- OpenPocketCine と、その通信部分をまとめた **OpenCine** は **Apache License 2.0** です。表示と変更点の明記を守れば、Video Mania に取り込んでよいライセンスです。
- 手順は **Bluetooth でペアリング → カメラの Wi-Fi 名とパスワードを Bluetooth で読む → iPhone をカメラの Wi-Fi に入れる → UDP 9004 でライブビュー(HEVC)** です。
- この手順で最小限のライブビューを `Sources/Osmo/` に試作しました。開発者モードのときだけ「設定」から開けます。
- 既定ではビルドに入りません。リポジトリ変数 `OSMO_LIVE` を `on` にしたビルドにだけ入ります。審査に出すビルドでは `OSMO_LIVE` をオフのままにしてください。

## 調べたもの

| プロジェクト | 中身 | ライセンス | 調べた版 |
| --- | --- | --- | --- |
| [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine) | iOS / Android のフィールドモニター。プロトコルの資料(`handbook/src/content/docs/protocol/`) | Apache 2.0 | `35f51dc` (2026-10-29) |
| [OpenCine](https://github.com/erik-sutton95/OpenCine) | OpenPocketCine が使う共通部品。DJI の通信は `Sources/OpenCineDJI`(バイト列)と `Sources/OpenCineDJIApple`(iOS の Bluetooth・Wi-Fi・UDP) | Apache 2.0 | `dd77b69e`(OpenPocketCine が固定している版) |
| [osmo-live](https://github.com/KevinCowleys/osmo-live) | Go の CLI。カメラから RTMP に配信させる。node-osmo の移植 | MIT | main |
| [node-osmo](https://github.com/datagutt/node-osmo) | TypeScript。BLE でペアリング・Wi-Fi・RTMP 配信 | MIT | main |
| [lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) | Pocket 3 の BLE 手順の詳しいメモ | MIT | main |
| [Osmosis](https://github.com/KonradIT/osmosis) | Android のメディア取り込みアプリ。OpenPocketCine が接続の考え方を学んだ元 | MIT | (README のみ) |

**osmo-live と node-osmo はライブビューを扱っていません。** カメラに「この RTMP サーバーへ配信して」と頼むだけで、映像は iPhone に来ません。
iPhone の中で映像を受けて表示する手順を公開しているのは OpenPocketCine / OpenCine だけです。

### ライセンス

- Apache 2.0 は、改変・再配布・アプリへの組み込みを認めます。条件は、ライセンス本文と NOTICE を付けること、改変したファイルに変更した旨を書くこと、商標を使わないことです。
- `Sources/Osmo/OsmoDUML.swift` と `OsmoVideoDepacketizer.swift` は OpenCine のコードを移植・簡略化しました。ほかのファイルは手順を参考に書き直しました。各ファイルの先頭に元と変更点を書いています。
- ライセンス本文と NOTICE は `docs/licenses/` に置きました。**配布するビルドに入れるときは、アプリの中にもライセンス表示が必要です**(まだ作っていません)。
- MIT のプロジェクトのコードは使っていません。

## 接続の手順(プロトコル)

Bluetooth は命令だけに使います。映像やファイルはカメラの Wi-Fi を通ります。暗号化はありません。

```text
BLE で探す → GATT 接続 → アプリのペアリング → Wi-Fi 名・パスワードを読む → カメラの Wi-Fi に入る → TCP 7001 → UDP 9004 → ライブビュー
```

### 1. Bluetooth で探す

- 絞り込まずに探します。Pocket 3 は広告に製造者データを入れないためです。
- DJI の会社 ID(`0x08AA`、`0xF7AA`)の製造者データか、名前で見分けます。
- 機種は製造者データから読めます。

| 機種 | 広告の機種番号 |
| --- | --- |
| Osmo Pocket 3 | `0x20`(実機で確認済み) |
| Osmo Pocket 4 | `0x21` |
| Osmo Pocket 4 Pro | `0x22` |

新しい形式の広告(5 バイト目の bit 2)では、10〜11 バイト目の製品番号(145 / 219 / 218)を上の番号に置き換えます。

### 2. GATT とアプリのペアリング

- サービス `FFF0`、通知 `FFF4`、書き込み `FFF5`。
- 両方の通知を有効にしてから `FFF4` に `01 00` を書くと、ペアリングの準備ができます。
- 命令は DUML という形式のフレームで `FFF5` に返事なしで書きます。続けて書くと落ちるので、約 120ms あけます。
- iOS の Bluetooth のペアリング(ボンディング)は使いません。代わりにアプリのペアリングをします。

| 命令(set/cmd) | 中身 | 返事 |
| --- | --- | --- |
| `0x00/0x2B` | 起こす `04 00`。そのあとは 1 秒ごとに `01 01` | — |
| `0x07/0x45` SetPairingPIN | アプリの識別子 + `"osmo"` | `00 01` ペアリング済み、`00 02` カメラの画面で許可が要る、`00 06` 後回し |
| `0x07/0x46` | 初回にカメラの画面で許可すると、カメラから「要求」として届く | アプリは返事のフレームで答える |

### 3. カメラの Wi-Fi 名とパスワード

| 命令 | 中身 |
| --- | --- |
| `0x53/0x10` | カメラの Wi-Fi(アクセスポイント)を起こす。Pocket 3 は答えないことが多い |
| `0x07/0x07` | Wi-Fi 名。返事は `[状態][長さ][文字列]` |
| `0x07/0x0E` | パスワード。**作らずに必ず読む**(Wi-Fi をリセットすると変わる) |

Pocket の Bluetooth の名前は Wi-Fi 名と同じです。Wi-Fi 名が読めないときは、名前を代わりに使えます。

### 4. カメラの Wi-Fi に入る

- iOS では `NEHotspotConfiguration` を使います。**Hotspot Configuration の権限(entitlement)が要ります。**
- カメラは `192.168.2.1` です。iPhone は DHCP で `192.168.2.2〜254` をもらいます。
- `apply` が成功しても、つながったとは限りません。パスワードが違っても成功が返ります。`192.168.2.x` が付くまで待ちます。
- 5.8GHz の地域では、カメラの電波が出るまで約 1 分かかることがあります。90 秒までやり直します。
- カメラの Wi-Fi にはインターネットがないので、iOS は既定の経路をモバイル通信のままにします。カメラへのソケットは `192.168.2.x` に結びつけて、モバイル通信を禁止します。
- 「ローカルネットワーク」の許可(`NSLocalNetworkUsageDescription`)が要ります。拒否されていると、接続は失敗せずに待ち続けます。
- VPN や広告ブロッカーは UDP 9004 を落とすことがあります。

### 5. データリンク(UDP 9004)

1. TCP `192.168.2.1:7001` に SetPairingPIN を 1 回書きます。**このソケットは閉じません。** 閉じるとカメラが接続を切ります。カメラは 1 秒 3 回ほど書いてくるので、読み捨てます。
2. UDP `192.168.2.1:9004` に 40 バイトのハンドシェイクを送ります。iPhone 側のポートは空いている番号にします。9004 にすると映像だけ来なくなります。
3. ハンドシェイクの返事と、34 バイトのテレメトリーを待ちます。テレメトリーの 8〜9 バイト目に 8 を足した値が、最初の命令番号です。
4. 登録 `0x00/0x81`・`0x00/0x88`、状態の購読 `0x00/0x99` を送ります。
5. `0x02/0x68`(`08`)のあとに `0x09/0xA8` を送ると、ライブビューが始まります。Pocket では受け手が `0x08` です。

1 つのデータグラムは `[8 バイトの運び用ヘッダー][12 バイトの経路ヘッダー][DUML]` です。種類(7 バイト目)は次のとおりです。

| pktType | 中身 |
| --- | --- |
| `0x00` | ハンドシェイク |
| `0x01` | テレメトリー(34 バイトのものは ACK の窓の位置を含む) |
| `0x02` | **映像** |
| `0x03` | 命令の返事 |
| `0x04` | 窓 ACK(アプリから約 40 回/秒) |
| `0x05` | 命令 |

続けて送り続けるもの:

- **窓 ACK を約 40 回/秒。** 映像の最新番号、命令の返事の番号、テレメトリーの番号の 3 つを返します。1 回/秒では足りません。
- **登録 `0x00/0x88` を約 1 秒ごと。** 最後の登録から 8〜10 秒で映像だけが止まります(Pocket 4 Pro で観察)。テレメトリーは続くので気づきにくいです。

### 6. ライブビュー

| 機種 | 符号化 | 大きさ |
| --- | --- | --- |
| Pocket 4 / 4 Pro | HEVC(H.265 Main) | 1280×720、約 25fps、約 4Mbps(資料は 4 Pro で観測)。**持ち主の Pocket 4 では 1920×1080 で届いた**。録画の設定とは別。「ライブビューの画質を上げる(調査)」を参照 |
| Pocket 3 | H.264 が観測されている | 720p、約 25fps |

- 1 枚は `00 00 01 ff` + 長さ(u32 リトルエンディアン)+ 8 バイトの 16 バイトのヘッダーで始まります。そのあとが Annex-B です。
- 1 枚は複数のパケットに分かれます。パケット番号は 8 ずつ進みます。欠けたらその 1 枚を捨てます。
- 符号化方式はパラメーターセット(HEVC の VPS/SPS/PPS、H.264 の SPS/PPS)だけで決めます。
- **定期的なキーフレームはありません。** `0x09/0xA8` がキーフレームの要求です。毎秒送ると逆にキーフレームが届かなくなります。止まったときに、数秒あけて 1 回だけ送ります。
- Pocket 4 のキーフレームは IDR ではなく BLA(NAL 種類 16)のことが多いです。
- ライブビューを止める命令はありません。切断してもカメラは送り続けます。

### 7. ファイルの取り込み(今後)

カメラの Wi-Fi の上で `GET http://192.168.2.1/v2?storage={0|1}&path=…` でファイルを取れます。一覧は DUML の `0x00/0x26`・`0x00/0x27` です。試作しました(下の「SD カードの動画を Wi-Fi で取り込む(調査)」)。

## Pocket 4 と Pocket 3 の違い

| | Pocket 4 / 4 Pro | Pocket 3 |
| --- | --- | --- |
| OpenPocketCine の扱い | ライブビュー・操作・ジンバルとも動作。主な試験機は 4 Pro | 動作するが、形式とファームウェアの組み合わせはまだ試験が足りない |
| ライブビューの符号化 | HEVC | H.264(観測された範囲) |
| BLE の広告 | 製造者データあり | 製造者データなし(名前で見分ける) |
| `0x53/0x10` | 答える | 答えないことが多い |
| 最初の絵 | — | 4K 25/30 で最初の絵が出ないことがある。1080 にしてから 4K に戻すと出た。**この試作には入れていない** |
| 色の命令 `0x02/0x42` | Normal `3F` など | Normal `00` など(値が違う) |

CineD の記事(2026 年 8 月)の時点では Pocket 4 Pro だけが試験済みでした。今の README は Pocket 4 と Pocket 3 も ✅ にしています。
Pocket 4(Pro ではない)は機種番号 `0x21` で、手順は 4 Pro と同じとされています。

## この試作(`Sources/Osmo/`)

| ファイル | 役目 |
| --- | --- |
| `OsmoDUML.swift` | DUML フレーム・CRC・UDP の包み・命令(OpenCine から移植) |
| `OsmoVideoDepacketizer.swift` | 映像のパケットを 1 枚に組み立てる・NAL の判定(OpenCine から移植) |
| `OsmoBluetoothLink.swift` | CoreBluetooth で探す・つなぐ・ペアリング・命令の読み書き |
| `OsmoWiFi.swift` | NEHotspotConfiguration でカメラの Wi-Fi に入る |
| `OsmoDatalink.swift` | TCP 7001・UDP 9004・ハンドシェイク・登録・窓 ACK・映像の受信 |
| `OsmoVideoDecoder.swift` | VideoToolbox で HEVC / H.264 を復号して表示 |
| `OsmoLiveMonitor.swift` | 全体の流れと状態 |
| `OsmoCameraControl.swift` | カメラ本体の録画の開始・停止と録画状態(「録画の操作(調査)」) |
| `OsmoLiveMonitorView.swift` | 画面(映像・状態・見つかったカメラ・ログ) |
| `OsmoRTMPServer.swift` | iPhone の中の RTMP サーバー(TCP 1935。「RTMP で受ける」) |
| `OsmoRTMPLink.swift` | Bluetooth で「インターネット共有に入って RTMP で送って」と頼む命令 |
| `OsmoRTMPSession.swift` | 高画質モードの全体(サーバー・命令・表示・録画) |
| `OsmoRTMPSection.swift` | 「高画質モード(RTMP・最大 1080p)」の欄 |

- すべて `#if OSMO_LIVE` で囲んでいます。`OSMO_LIVE` がオフのビルドには、コードも権限も利用目的の文も入りません。
- 開き方: 「設定」のバージョンの行を **7 回** タップすると開発者モードがオンになります(もう 7 回でオフ)。5 回で出る「サポート用の情報」はそのままです。開発者モードの欄に「Osmo Pocket ライブビュー(実験)」が出ます。
- `AppSettings.developerMode` は既定でオフです。
- 入れていないもの: 再接続の細かい修復、カメラの操作(設定・ズーム。録画は下の「録画の操作(調査)」で試作、ボタンは未配置)、ジンバル、ファイルの取り込み、Pocket 3 の最初の絵の回避策、ライセンス表示の画面。

### ビルドに入れる方法

**テスト用の 1 回だけ入れる(おすすめ)**

1. GitHub の Actions → TestFlight → Run workflow を押します。
2. Branch を選び、「Osmo Pocket の実験を入れる」にチェックを入れて実行します。
3. ワークフローが App Store Connect API で App ID の **Hotspot** の機能をオンにします(すでにオンなら何もしません)。そのあとアプリを作って TestFlight に送ります。

API キーに権限がなくて Hotspot をオンにできないときは、そのステップが失敗します。
その場合は developer.apple.com の Identifiers → `com.yuyaogawa6960.videomania` で Hotspot にチェックを入れてください。

**ずっと入れる**

リポジトリ変数 `OSMO_LIVE` を `on` にすると、main への push でも入ります。**審査に出す前に必ず消してください。**

`main` への push では、チェックも変数もなければ、CI が `project.yml` の `# >>> osmo-live` と `# <<< osmo-live` のあいだを消して作ります。
コード・権限・利用目的の文のどれもビルドに入りません。

## リスク

- **ファームウェアの更新で動かなくなる。** 手順は DJI が公開したものではなく、Mimo の通信を観察した結果です。DJI はいつでも変えられます。OpenPocketCine の資料も「試したファームウェアでの観察で、DJI の約束ではない」と何度も書いています。
- **DJI の規約。** DJI のアプリや製品の利用規約には、ソフトウェアのリバースエンジニアリングを禁じる条項があるのが一般的です。この試作は DJI のコードや SDK を含まず、公開されたオープンソースの手順でカメラと通信するだけです。それでも規約上の扱いは確認していません。製品として出す前に、規約を読むか専門家に確かめてください。
- **商標。** 画面やストアの説明で「DJI」「Osmo」を使うと、DJI の公式機能と誤解されるおそれがあります。機種を示すためだけに使い、公式ではないと明記します。
- **App Store の審査。** Bluetooth・ローカルネットワークの許可と Hotspot の権限は、使い道の説明を求められます。隠し機能のための許可は審査で問題になりえます。そのため既定ではビルドに入れていません。
- **カメラへの影響。** OpenPocketCine は、知らない命令の値を総当たりで送ったら Osmo Nano が固まり、電源を入れ直す必要があったと書いています。この試作は観察済みの命令だけを送ります。
- **iPhone の Wi-Fi が切り替わる。** 使っているあいだ、iPhone はカメラの Wi-Fi に入ります。インターネットはモバイル通信になります。切断すると設定を消して元の Wi-Fi に戻します。

## 実機で確かめること(未検証の一覧)

**すべて未検証です。** 順に試し、つまずいたところのログを送ってください。

1. **ビルドが通るか。** この環境には Swift がなく、コンパイルできていません。`OSMO_LIVE` を on にした TestFlight のビルドでエラーが出たら、ログを貼ってください。
2. 開発者モード: バージョンの行を 7 回タップすると「開発者モード」の欄が出て、もう 7 回で消えるか。5 回の「サポート用の情報」が今まで通りか。
3. 「カメラを探す」で Bluetooth の許可が出て、Pocket 4 が「Osmo Pocket 4」と表示されるか(機種が「機種不明」なら、ログの `found` の行を送ってください)。
4. タップして、初回はカメラの画面に許可が出るか。許可すると先に進むか(ログの `pair:` の行)。
5. Wi-Fi 名とパスワードが読めるか(`wifi: ssid … (password N chars)`)。
6. 「接続しますか」が出て、カメラの Wi-Fi に入れるか(`wifi: joined, local 192.168.2.x`)。5.8GHz だと 1 分ほどかかることがあります。
7. 「ローカルネットワーク」の許可が出るか。許可したあと `datalink: TCP 7001 poke ready` と `handshake acked` が出るか。
8. `decoder: codec HEVC` と `format 1280x720` が出て、映像が出るか。fps が 20〜25 くらいか。
9. 1 分以上つないだまま、映像が止まらないか。止まったら `keyframe request` の行のあとに戻るか。
10. 「切断」で iPhone が元の Wi-Fi に戻るか。もう一度つなげるか(2 回目はペアリング済みで速いはず)。
11. 画面を閉じたり、アプリを裏に回したりしたあと、普通の編集機能に影響がないか。
12. (あれば)Pocket 3 でも同じことを試す。H.264 と表示されるはずです。

## 参考

- CineD: [OpenPocketCine: Free Open-Source Field Monitor App Brings Waveforms, False Color, and LUTs to DJI Osmo Cameras](https://www.cined.com/openpocketcine-free-open-source-field-monitor-app-brings-waveforms-false-color-and-luts-to-dji-osmo-cameras/)
- OpenPocketCine の資料: <https://opencapture.org/openpocketcine/docs/>(プロトコル: connection / ble / wifi / duml-transport / live-view / commands / media)

## 録画の操作(調査)

> **状態: 調査と試作。実機ではまだ一度も試していません。** 調べたのは 2026-10-31。

### 結論

- **カメラ本体の SD カードへの録画は、DUML の `0x02/0x02` で始め・止めます。** 中身は 1 バイトで、`01` が開始、`00` が停止です。
- 受け手はカメラ(`0x01`)、flags は `0x40`(要求)。**Bluetooth ではなく、Wi-Fi のデータリンク(UDP 9004)で送ります**(OpenCine がそうしている)。
- トグルではありません。録画中にもう一度 `01` を送ると、カメラは `DF`(断る)を返します。
- **録画しているかどうかは、カメラが勝手に送ってくる `0x02/0x80` で分かります。** 先頭の 4 バイト(u32 リトルエンディアン)の **bit 7(`0x80`)が 1 なら録画中**です。この状態は命令の返事より約 1 秒遅れて変わります。
- 録画される映像はカメラの録画設定そのまま(フル画質)です。ライブビュー(720p)とは関係ありません。
- 出どころは Apache 2.0 の OpenCine / OpenPocketCine で、Pocket 4 Pro と Pocket 3 の実機で DJI Mimo の通信を記録した資料があります。**信頼度は高め**と判断し、`Sources/Osmo/OsmoCameraControl.swift` に試作しました。

### 見つけたもの

| 出どころ | 中身 | ライセンス | 確かめた機種 | 信頼度 |
| --- | --- | --- | --- | --- |
| [OpenCine `Sources/OpenCineDJI/Commands.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e/Sources/OpenCineDJI/Commands.swift)(`dd77b69e`) | `recordStart` = `0x02/0x02` `[01]`、`recordStop` = `[00]`。受け手 `0x01`、flags `0x40`。「トグルではない。録画中の `01` には `df`」 | Apache 2.0 | OpenPocketCine が使う共通部品 | 高 |
| [OpenCine `CameraStatus+DJIWire.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e/Sources/OpenCineDJI/CameraStatus%2BDJIWire.swift) | `0x02/0x80`(13 バイト以上): flags の `0x80` = 録画中、`0x4000_0000` = 再生中。@5 容量、@9 空き(MiB)、@17 u32 残り秒、@29 u16 経過秒、@57 撮影モード | Apache 2.0 | 同上 | 高 |
| [OpenCine `DjiAppleControlExchange.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e/Sources/OpenCineDJIApple/DjiAppleControlExchange.swift) | 操作の命令は `via=datalink`。「録画の状態は ACK より約 1 秒遅れる」 | Apache 2.0 | 同上 | 高 |
| [OpenCine `CameraControl+DJIWire.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e/Sources/OpenCineDJI/CameraControl%2BDJIWire.swift) `CaptureCommand` | 写真モードは `0x02/0x01` `[01]`。Pocket 3 のタイムラプスは `0x02/0x01` の `01`/`00`。それ以外(Pocket 4 のタイムラプスも)は `0x02/0x02` | Apache 2.0 | 同上 | 中(モード別は一部だけ) |
| [OpenPocketCine handbook `protocol/commands.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/protocol/commands.md)(`35f51dc`) | 「`0x02/0x02` record start/stop、`[01]` / `[00]`、Pocket 4 は `rcv=0x01`」 | Apache 2.0 | — | 高 |
| [OpenPocketCine `devices/pocket-4-pro/slow-motion.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/devices/pocket-4-pro/slow-motion.md) | Mimo の記録: 4K/240 で `02/02 [01]` → 録画状態がオン、`02/02 [00]` → オフ。1080p/120 では `[01]` を 2 回送り直し、返事 `00` のあと状態がオン | Apache 2.0 | **Pocket 4 Pro**(Mimo の通信の記録) | 高 |
| [OpenPocketCine `devices/pocket-3/media.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/devices/pocket-3/media.md)・[`connection.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/devices/pocket-3/connection.md) | `0x02/0x02` が受け付けられ、録画状態が続いて変わった。OpenPocketCine 0.1.0 でも開始・停止し、SD のファイル(2.7K/25、HEVC)を確認 | Apache 2.0 | **Pocket 3**(Mimo と OpenPocketCine の両方) | 高 |
| [dji-firmware-tools `dji-dumlv1-camera.lua`](https://github.com/o-gs/dji-firmware-tools/blob/master/comm_dissector/wireshark/dji-dumlv1-camera.lua) | 古い DJI 機(ドローン)の解析表。cmdset `0x02` の `0x01` = Do Capture Photo、`0x02` = Do Record、`0x80` = Camera State Info(Record State はマスク `0x00C0`) | **GPL-3.0**(コードは使っていない。番号の裏付けにだけ使った) | ドローンのカメラ(Pocket ではない) | 裏付けとして中 |
| [Osmosis](https://github.com/KonradIT/osmosis) | DUML の命令表に録画は無い。別に DJI の R-SDK(`0x1D/0x03` で録画)を移植しているが、Osmo Action / 360 向け | MIT | Action / 360 | Pocket には使えない |
| [DJI Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) | DJI 公式の BLE リモコン例(R-SDK、`0xAA` で始まる別の形式)。対応は **Osmo 360 / Action 6・5 Pro・4 のみ** | README は MIT 表記(GitHub の判定は NOASSERTION) | Action / 360 | **Pocket は対象外** |
| [node-osmo](https://github.com/datagutt/node-osmo)・[osmo-live](https://github.com/KevinCowleys/osmo-live)・[lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) | ペアリング・Wi-Fi・RTMP 配信だけ。録画の命令は無い | MIT | Pocket 3 | 該当なし |

- OpenPocketCine の README と CineD の記事にも「iOS 版は録画の開始・停止ができる」とあります。作者は「つながりを信用できるまで、録画はカメラ本体で確かめて」と書いています。
- **Pocket 4(Pro ではない)での記録は見つかりませんでした。** 受け手 `0x01` は「Pocket 4」と書かれていますが、詳しい記録は 4 Pro と Pocket 3 のものです。手順は 4 Pro と同じとされています。

### 命令の形

```text
送る(データリンク、pktType 0x05):
  sender 0x02  receiver 0x01  flags 0x40  set 0x02  cmd 0x02  payload [01] 開始 / [00] 停止
返事(pktType 0x03):
  set 0x02  cmd 0x02  flags に 0x80  payload [00] 受け付け / [DF] 断り
状態(カメラから勝手に届く):
  set 0x02  cmd 0x80  payload の u32LE@0 の bit 7 (0x80) = 録画中
                      u32LE@17 = 残り秒、u16LE@29 = 経過秒、@57 = 撮影モード(0x01 = Video)
```

注意:

- **写真モードでは `0x02/0x02` ではなく `0x02/0x01`** です(Video モードで `0x02/0x01` を送ると `D9` が返る)。Pocket 3 のタイムラプスも `0x02/0x01`。この試作は Video 用の `0x02/0x02` だけで、撮影モードが Video(`0x01`)でないときはログに書きます。
- Mimo は録画開始のあとに別の設定(美肌の 62 バイト)を送り、それに `DF` が返っても録画は続いていました。**`DF` がどの命令の返事かを取り違えない**ことが大事です。
- Pocket 4 Pro では、返事が無いとき Mimo が `[01]` を送り直していました。試作も 1.5 秒返事が無ければ 1 回だけ送り直します(録画中の `01` は `DF` で無害とされる)。
- 経過秒 `@29` を録画していないときに何が入るかは確かめていません。

### 試作(`Sources/Osmo/OsmoCameraControl.swift`)

- `#if OSMO_LIVE` の中です。`OsmoLiveMonitor.camera`(`OsmoCameraControl`)として使えます。
- `startRecording()` / `stopRecording()`: 命令を送り、カメラの `0x02/0x80` で状態が変わるのを最長 4 秒待ちます。**画面の「録画中」は送った命令ではなく、カメラの報告だけで決めます。**
- `recordingState`(`.unknown` / `.idle` / `.recording`)、`elapsedSeconds`、`remainingSeconds`、`shootingModeRaw`、`isBusy`、`lastMessage`、`onRecordingChanged`。
- データリンクの `OsmoDatalink.sendCommand(_:)` を 1 つ足しました(元の送信は `private` だったため)。`OsmoLiveMonitor` はデータリンクを開いたら `camera.attach(link)`、切断で `camera.detach()`、`0x02/0x02`・`0x02/0x80` のフレームを `camera.handle(_:)` に渡します。
- ボタンはまだ画面にありません(`OsmoLiveMonitorView.swift` は別の作業で変更中)。

### 実機で確かめること(録画)

**すべて未検証です。** SD カードを入れ、カメラを **Video モード** にしてから試してください。

1. **ビルドが通るか。** `OSMO_LIVE` を on にした TestFlight のビルドで確かめます。
2. ライブビューまでつないだあと、ログに `record: camera reports idle (flags …)` が出るか。出ない場合、`0x02/0x80` が届いていません(ログを送ってください)。
3. 「録画開始」で、**カメラ本体の画面が録画中(赤い印と時間)になるか。** ログに `record: reply 0x02/0x02 00` と `record: camera reports RECORDING` が出るか。
4. 録画中に経過秒が 1 秒ずつ増えるか(`elapsedSeconds`)。残り秒がそれらしい値か。
5. 「録画停止」で、カメラ本体の録画が止まり、ログに `camera reports idle` が出るか。
6. 撮ったファイルが **SD カードに、カメラの録画設定どおりの画質で** 残っているか(Mimo か SD カードで確認)。
7. 録画中にもう一度「録画開始」を押したとき、`DF` が返り、録画が止まらないか。
8. カメラ本体のボタンで録画を始め・止めたとき、アプリの表示がついてくるか(`0x02/0x80` の報告)。
9. 写真モードで「録画開始」を押したとき、ログに `shooting mode 0x… is not Video` が出て、カメラが断る(`DF` など)だけで固まらないか。**固まったら電源を入れ直し、そのモードでは押さないでください。**
10. 録画中にライブビューが止まらないか(fps が下がらないか)。
11. (あれば)Pocket 3・Pocket 4(Pro ではない)でも同じことを試す。

## ライブビューの画質を上げる(調査)

> **状態: 調査のみ。コードは変えていません。** 調べたのは 2026-10-31。

### 結論

- **ライブビュー(UDP 9004 の映像)の解像度やビットレートを上げる DUML 命令は、公開資料には見つかりませんでした。** 1080p 高ビットレート・2.7K・4K に切り替える方法は、今のところ分かっていません。
- そのため、`setLiveViewQuality(_:)` と画面の「ライブビューの画質」は **作っていません**(当て推量の命令は送らない方針)。
- 持ち主の Pocket 4 では、ライブビューが **1080p** で届いています。資料(Pocket 4 Pro で観測)は 1280×720・約 25fps・約 4Mbps と書いています。機種(Pocket 4 と 4 Pro)かファームウェアの違いと思われますが、確かめた記録はありません。**アプリ側で何かを変えた結果ではありません。**
- ライブビューは **録画の設定とは別** です。資料には「4K 50p で録画していても、モニターは約 25fps のまま」とあります。録画の解像度を上げても、ライブビューは上がりません。
- **フル画質がほしいときは、カメラ本体の SD カードに録画し(`0x02/0x02`)、あとで Wi-Fi の HTTP(`GET http://192.168.2.1/v2?...`)で取り込む** のが確かな方法です。iPhone でライブビューを録るのは「控え」や「すぐ使う短い動画」向きです。

### 調べたもの

| 出どころ | 中身 | ライセンス | 確かめた機種 | 信頼度 |
| --- | --- | --- | --- | --- |
| [OpenPocketCine handbook `protocol/live-view.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/protocol/live-view.md) | Pocket 4 / 4 Pro: 1280×720・約 25fps・約 4Mbps、録画の形式とは無関係。Pocket 3: 720p。**ライブビューの画質を変える設定は書かれていない。** 設定を変える命令(録画・FORMAT・COLOR など)で映像が一瞬止まることはある | Apache 2.0 | Pocket 4 Pro(実測)、Pocket 3 | 高(「命令が無い」ことの裏付けとして) |
| [OpenPocketCine handbook `protocol/commands.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/protocol/commands.md) | 命令表にライブビューの画質の項目は無い。`0x09/0xA8` は「ライブビュー開始(キーフレーム要求)」だけ | Apache 2.0 | — | 高 |
| [OpenCine `Sources/OpenCineDJI/Commands.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e/Sources/OpenCineDJI/Commands.swift)(`dd77b69e`) | `liveViewEnable` = `0x09/0xA8`、受け手 `0x08`、中身 `00 04 02 00 00 00 00 00 00 00`(Mimo の通信をそのまま写したもの。**各バイトの意味は書かれていない**)。`liveViewPrepare` = `0x02/0x68` `[08]`(実は AE の命令と同じバイト列) | Apache 2.0 | Pocket 4 Pro ほか | 高(画質の引数があるとは書いていない) |
| [OpenPocketCine `devices/pocket-3/livestream.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/main/handbook/src/content/docs/devices/pocket-3/livestream.md) | **RTMP 配信**(ライブビューとは別物)。`0x08/0x78` で設定、Mimo の選択肢は 480p / 720p / 1080p、25 / 30fps。1080p/25 の設定バイト `0A 70 17 02 01 02 00 00 00`(`0A` = 1080p、`70 17` = 0x1770 = 6000 kbps と読めるが資料は意味を確定していない)。カメラが **ローカルネットワークの RTMP サーバーへ直接** 送る。受け手で 1920×1080 H.264 High 25fps を確認 | Apache 2.0 | **Pocket 3 だけ**。Pocket 4 Pro は設定の形式が違う(版 01 の JSON)とだけ書かれ、詳細なし | 中(Pocket 4 では未確認) |
| [Osmosis `osmosis_cmds.kt`](https://github.com/KonradIT/osmosis)(djictl の移植) | RTMP 設定 `0x08/0x78` の解像度は 480p `0x47`・720p `0x04`・1080p `0x0A` のみ。「2.7K / 4K の選択肢は無い」。ビットレートは kbps(u16)、fps は 30 固定 | MIT | Action 系・Pocket 3 | 中 |
| [node-osmo](https://github.com/datagutt/node-osmo)・[osmo-live](https://github.com/KevinCowleys/osmo-live)・[lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) | RTMP 配信の手順だけ(上と同じ `0x08/0x78`)。iPhone へのライブビューは扱っていない | MIT | Pocket 3 | 該当なし |
| [dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) の解析表 | cmdset `0x02` に `0x8B` "Racing Liveview Format Set"、`0x93` "TransCode Control"。cmdset `0x09`(HD Link)に `0x14` "Max Video Bandwidth Set"、`0x39` "Liveview Config Set" など。cmdset `0x07`(Wi-Fi)に `0x2C` "Ap Code Rate Set"。**名前だけで中身の形式は無く、ドローン用。** `0x09/0xA8` は表に無い | GPL-3.0(コードは使わない) | 古いドローン | **低**(Pocket で使える根拠なし) |
| DJI 公式 SDK(Mobile / Onboard / Payload SDK) | ドローン向け。Osmo Pocket は対象外 | — | — | 該当なし |
| CineD の Pocket 4 発表記事 | Pocket 4 は Wi-Fi 6、Mimo への転送は最大 90MB/s。有線(USB-C)の映像出力で最大 4K/60 の配信ができる | 記事 | Pocket 4 | 参考 |

ウェブ検索でも、Pocket 4 のライブビュー解像度を変える方法の記事は見つかりませんでした。DJI Mimo にも「ライブビューの画質」の設定は見当たりません(配信の画質設定は RTMP 配信用)。

### 候補(確かめていない。実装しない)

- **`0x09/0xA8` の中身の `04` や `02`。** 意味の分からないバイトです。画質の指定の可能性はありますが、Mimo がこの値以外を送った記録はありません。変えるとライブビューが始まらない恐れがあります。
- **`0x02/0x93`・`0x02/0x8B`・`0x09/0x14`・`0x09/0x39`。** ドローン時代の名前だけです。中身の形式が分からず、送ると何が起きるか分かりません。
- **RTMP 配信(`0x08/0x78`)を iPhone の中の RTMP サーバーで受ける。** 1080p・約 6Mbps の H.264 は Pocket 3 で確認済みです。ただし (1) 最大でも 1080p(2.7K / 4K は無い)、(2) Pocket 4 では設定の形式が違い詳細不明、(3) カメラが「ネットワークに入る」(`0x07/0x47`)前提で、iPhone がカメラの Wi-Fi に入っている今の形とは別の接続になる、(4) iPhone で RTMP サーバーを動かす実装が要る、という壁があります。今のライブビュー(すでに 1080p)より大きく良くなる保証もありません。→ その後、持ち主の希望で試作しました(下の「RTMP で受ける」)。

### Wi-Fi で運べる量の目安

- カメラの Wi-Fi(Pocket 4 は Wi-Fi 6)は、ファイル転送で数十 MB/s 出ます。電波の空きとしては 4K の録画ビットレート(100Mbps 前後)でも運べる計算です。
- **ただし、ライブビューは UDP で、欠けたパケットは送り直されません。** この試作は 1 枚の途中が欠けるとその 1 枚を捨てます。ビットレートが上がるほど 1 枚あたりのパケットが増え、捨てる枚数が増えます。実用の上限は電波より **カメラのライブビュー用エンコーダー** が決めていると考えられ、資料の実測は約 4Mbps(720p)でした。
- iPhone 側の録画(`OsmoStreamRecorder`)は届いた映像をそのまま MP4 に入れるだけ(再エンコードしない)なので、画質はカメラが送る映像で決まります。

### 録画中に解像度が変わったとき

- `OsmoStreamRecorder` は、パラメーターセットの大きさが変わると(例: 1280×720 → 1920×1080)**そのファイルを閉じます**(ログ `recorder: size changed …, finishing`)。今後もし画質の切り替えを作るなら、**録画中は切り替えを無効にする** 必要があります。

### 持ち主に確かめてほしいこと

1. ライブビュー画面の表示(`幅×高さ`)が、**毎回** 1920×1080 になるか。カメラの録画設定(4K / 2.7K / 1080p、fps、Normal / D-Log)を変えると変わるか。
2. iPhone で **ちょうど 60 秒** 録ったファイルの大きさ。大きさ(MB)× 8 ÷ 60 が実際のビットレート(Mbps)です。例: 30MB なら約 4Mbps。
3. そのときの fps(画面の表示)。25 か 30 か、落ちることがあるか。
4. 機種名とファームウェアの版(Mimo の「デバイス情報」)。Pocket 4 Pro の資料(720p)との違いを説明するのに使います。
5. (できれば)DJI Mimo でつないだときのライブビューが同じ 1080p に見えるか。
6. 画質に満足できないときは、カメラ本体の SD 録画(`0x02/0x02`)+ あとで取り込み、の流れを優先して作るか決めてください。

## RTMP で受ける

> **状態: 試作。実機ではまだ一度も試していません。コンパイルもできていません。** 作ったのは 2026-10-31。
> 持ち主の話では、前に Pocket 4 で RTMP 配信ができていた(DJI Mimo からと思われる)ので、カメラは 1080p の RTMP を送れます。

### 考え方

- カメラが **iPhone のインターネット共有(ホットスポット)に入り**、RTMP で **iPhone の中の RTMP サーバー** に送ります。URL は `rtmp://172.20.10.1:1935/live/videomania`(インターネット共有での iPhone の住所はいつも `172.20.10.1`)。
- UDP 9004 のライブビューより画質が高い(最大 1080p、ビットレートも高い)。**RTMP には 2.7K / 4K がありません**(Mimo の選択肢も、node-osmo・djictl の値も 480p / 720p / 1080p だけ)。
- ライブビューとは同時に使えません(ライブビューは iPhone がカメラの Wi-Fi に入る。RTMP はカメラが iPhone に入る)。高画質モードを始めるとライブビューは止まり、ライブビューを始めると高画質モードは止まります。
- 届いた映像は再エンコードせずに `.mp4` に入れます(`OsmoStreamRecorder` をそのまま使う)。カメラの音(AAC)が届けばそれを入れ、届かなければ iPhone のマイクを使えます。

### 始め方は 2 つ

1. **Bluetooth で頼む(主な方法)**: 画面にインターネット共有の名前とパスワードを入れて「開始」。Keychain に保存します(この端末だけ。ログには文字数しか出しません)。
2. **DJI Mimo から始める(Bluetooth の命令を使わない)**: 「受信だけ始める」を押し、DJI Mimo の「ライブ配信」→「RTMP」に画面の URL(コピーできる)を入れて開始し、すぐ Video Mania に戻る。Mimo で配信が始まっている間、Video Mania は裏にいるので、受けられるのは 30 秒ほど(`beginBackgroundTask`)です。間に合わないときは、Mimo を別の端末(iPad など)で動かす方法もあります(未確認)。

### Bluetooth の命令(資料にあるものだけ)

| 順 | 命令 | 受け手 | 中身 | 返事 | 出どころ |
| --- | --- | --- | --- | --- | --- |
| 0 | ペアリング `0x07/0x45` ほか | `07` | ライブビューと同じ | `00 01` / `00 02` | 既存 |
| 1 | `0x02/0xE1` ライブ配信のモード | `08` | `1A` | `00` | OpenPocketCine `devices/pocket-3/livestream.md`、`protocol/ble.md` |
| 2 | `0x07/0x47` Wi-Fi に入る | `07` | `[長さ][名前][長さ][パスワード]` | `00 00`(4 Pro は `00 00 00` も)。`01 FF` は 5 秒待ってやり直し(最大 3 回) | 同上、OpenCine `MulticamJoinPolicy`、node-osmo、lib-osmo-ble |
| 3 | `0x08/0x78` RTMP の設定 | `08` | 下の表 | `00` | 同上、OpenPocketCine commit `137433b` の `MulticamCommands.swift` |
| 4 | `0x02/0x8E` 開始 | `08` | `01 01 1A 00 01 01` | `00` | 同上 |
| 止める | `0x02/0x8E` 終わり | `08` | `01 01 1A 00 01 02` | (記録なし。RTMP が閉じる) | 同上 |

`0x08/0x78` の中身は機種で違います。

| 機種 | 形 | 9 バイトの設定 | 出どころ・確かさ |
| --- | --- | --- | --- |
| Pocket 3 | 版 00: `00 [本体の長さ u16le] [9 バイト] [URL の長さ u16le] [URL]`(本体 = 9 + 2 + URL) | Mimo が 1080p/25 で送ったのは `0A 70 17 02 01 02 00 00 00`。この試作は node-osmo の読み方(`0A` = 1080p、`70 17` = 6000kbps、6 バイト目 = fps、25 = `02`・30 = `03`)で **ビットレートと fps だけ** を変える。既定は 1080p・30fps・20Mbps、選べるのは 20 / 16 / 10Mbps(30fps)と Mimo と同じ 6Mbps(25fps) | 形は OpenPocketCine の Mimo の記録(Pocket 3 で確認)。30fps と高いビットレートは node-osmo の読み方による推測を含む |
| Pocket 4 / 4 Pro | 版 01: `01 [本体の長さ u16le] [9 バイト] [JSON の長さ u16le] [JSON]`(本体は先頭 3 バイトを除く) | Pocket 3 と同じ `0A 70 17 02 01 02 00 00 00`(1080p・25fps・6000kbps)をそのまま。JSON は `{"EnhancedRTMP":false,"codec":"HEVC","orientation":"landscape","rtmpAddress":"<URL>","supportStopLive":false,"watermark":0}`(キーを並べ、`/` をエスケープしない) | OpenPocketCine の試作(commit `137433b`、2026-09-23)。資料では Pocket 4 Pro で「設定・開始とも `00`」。**Pocket 4(Pro ではない)では記録が無い**。30fps や別のビットレートの値は分からないので送らない |

- 機種は Bluetooth の広告(`0x21` / `0x22` = Pocket 4 系、`0x20` = Pocket 3)と名前で決め、分からなければ Pocket 3 として扱います(Pocket 3 は広告に機種を入れないため)。画面の「カメラの機種」で選び直せます。
- DJI の公式資料では、Pocket 4 系の Mimo の RTMP は 1080p30 まで、3 または 6Mbps です(OpenPocketCine `docs/research-multicam-networking.md` が引く DJI のヘルプ)。6Mbps は Pocket 4 の上限と思われます。
- **Pocket 4 の 1080p/30 の値と、JSON の `EnhancedRTMP: true` にしたときの動きは分かっていません。** 確かめるには、DJI Mimo で 1080p/30 を選んで配信したときの Bluetooth の通信の記録(iPhone の sysdiagnose か Android の HCI ログ)が要ります。

### RTMP サーバー(`OsmoRTMPServer.swift`)

DJI の RTMP の送り手がどの実装かは分からないので、ふつうの送り手の違いをなるべく受けるようにしました。

- ハンドシェイク: 単純な方式と、Flash 方式(C1 のダイジェストを HMAC-SHA256 で確かめ、S1/S2 にもダイジェストを付ける)の両方。
- チャンク: fmt 0〜3、1〜3 バイトのチャンク ID、拡張タイムスタンプ(続きの塊で繰り返す送り手・繰り返さない送り手の両方)、Set Chunk Size(最大 16MB)、Abort、Window Ack Size、受領の返事、Ping、集約メッセージ。
- 命令: `connect` → Window Ack Size・Set Peer Bandwidth・Set Chunk Size 4096・`_result`。`releaseStream` / `FCPublish`(`onFCPublish` も)/ `createStream` / `publish` → Stream Begin・`onStatus NetStream.Publish.Start`。アプリ名・配信キーは何でも受けます。
- 映像: 旧来の FLV の AVC(ID 7)、旧来の HEVC(ID 12。Pocket 4 Pro の JSON は `codec: HEVC`・`EnhancedRTMP: false` なので、これで届く可能性が高い)、Enhanced RTMP の `hvc1` / `avc1`(SequenceStart・CodedFrames・CodedFramesX)。設定やフレームが Annex-B で届いても受けます。
- 音: AAC(AudioSpecificConfig・生のフレーム、ADTS 付きも)、Enhanced RTMP の `mp4a`。
- `@setDataFrame onMetaData` の幅・高さ・fps・ビットレートはログに出します(画面の数字は実際に届いた映像から数えます)。
- 新しい送り手が配信を始めたら古い接続を切ります(カメラのつなぎ直し)。20 秒黙った接続、30 秒たっても配信を始めない接続は閉じます。
- チャンクと AMF0 の読み方は OpenPocketCine の試作(commit `d2851068` の `RTMPIngest.swift`・`MultiviewRTMPServer.swift`、Apache 2.0)を参考に書き直しました。

### 録画と表示

- 表示は `OsmoVideoDecoder`(ライブビューと同じ部品)。キーフレームには設定のパラメーターセットを前に付けて渡します。
- 録画は `OsmoStreamRecorder` に足した入口(`observe(accessUnit:timestampMs:compositionMs:codec:)`、`setCameraAudioFormat`、`observeCameraAudio`)で書きます。時刻はカメラが付けた RTMP の時刻をホストの時計に写したもの。B フレームのための composition time も入れます。カメラの AAC はそのまま(パススルー)入れます。
- 止めたら「プロジェクトに入れる」「写真に保存」「破棄」。録画中は「停止」と「閉じる」を押せません。アプリが裏に回ると録画はそこまでで閉じます。
- 受信中は画面を自動で消しません(`IdleTimerGuard`)。
- 権限: `NSLocalNetworkUsageDescription` の文に RTMP を足しました(`project.yml` の `# >>> osmo-live` の中)。Bonjour は使わないので `NSBonjourServices` は要りません。

### 実機で確かめること(RTMP)

**すべて未検証です。** ログ(画面の「ログを共有」)の `rtmp:` の行を送ってください。

1. **ビルドが通るか**(`OSMO_LIVE` を on にした TestFlight)。
2. iPhone の「設定」→「インターネット共有」で「ほかの人の接続を許可」と「互換性を優先」をオンにする。
3. 「高画質モード」に名前とパスワードを入れて「開始」。状態が「カメラ接続中(カメラを探しています…)」→「ペアリング中…」→(初回はカメラの画面で許可)→「ライブ配信の準備をしています…」と進むか。ログの `rtmp: camera … -> config v01 JSON (Pocket 4)` で機種の判定が合っているか。
4. `rtmp: prepare reply 00` が出るか。カメラの画面がライブ配信の画面に変わるか。
5. `rtmp: join reply 00 00` が出て、インターネット共有の画面に「1 台接続中」が出るか。`01 FF` のあと成功するか。失敗したら返事の値を。
6. `rtmp: configure reply 00`、`rtmp: start reply 00` が出るか。
7. 初回は「ローカルネットワーク」の許可が出るか(出ないまま `listener waiting` が出たら設定アプリで許可)。
8. `rtmp: connection from 172.20.10.x` → `rtmp: handshake …` → `rtmp: connect app=live …` → `rtmp: publish …` と進むか。どこで止まるか。**`handshake with digest` か `simple` か** も知りたいです。
9. `rtmp: video HEVC` か `H.264` か、`rtmp: metadata …` の中身(width・height・framerate・videodatarate・encoder)。`rtmp: unsupported …` が出たらその行を。
10. 映像が出て、状態が「受信中 1920×1080 25fps 6.0Mbps」のようになるか。fps とビットレートの数字。
11. 「録画」→ 60 秒 → 「停止」で、ファイルが写真アプリで再生できるか。音がカメラの音か(ログ `recorder: started … + camera audio`)。ファイルの大きさ(MB × 8 ÷ 60 = Mbps)。
12. 「プロジェクトに入れる」で編集画面に入るか。
13. 「停止」でカメラの配信が終わるか(`rtmp: sent stop`、カメラの画面が戻るか)。もう一度「開始」できるか。
14. 10 分以上続けて止まらないか。iPhone とカメラが熱くならないか。電池の減り。
15. **DJI Mimo から**: 「受信だけ始める」→ Mimo の「ライブ配信」→「RTMP」に URL を貼って開始 → すぐ Video Mania に戻る。映像が来るか。来なければ Mimo の画面のエラーと、ログの `rtmp: connection from` の有無を。
16. (Pocket 3 があれば)画質「1080p 30fps 20Mbps」で `configure reply 00` になるか。断られたら 16 / 10Mbps、それでもだめなら「25fps 6Mbps(Mimo と同じ)」で。
17. (分かれば)DJI Mimo で 1080p/30 を選んで配信したときの Bluetooth の記録。Pocket 4 の 30fps の値を知るのに使います。

## SD カードの動画を Wi-Fi で取り込む(調査)

> **状態: 調査と試作。実機ではまだ一度も試していません。** 調べたのは 2026-10-31。
> 試作は `Sources/Osmo/OsmoMediaBrowser.swift`(`#if OSMO_LIVE` の中)。ライブビュー画面の「カメラの動画を取り込む」から開きます。

### 結論

- **できます(公開資料で裏付けあり)。** カメラの Wi-Fi に入ったまま、**`GET http://192.168.2.1/v2?storage={0|1}&path=<カメラの中のパス>`** で元のファイルをそのまま取れます。サーバーは lighttpd/1.4.55、ポート 80、**認証もトークンも無し**(カメラの Wi-Fi に入れること自体が鍵)。
- **HTTP には一覧が無い。** `/v2` 以外の URL は接続を切られ、フォルダーの一覧も返しません。一覧は **DUML のデータリンク(UDP 9004)で `0x00/0x26` を送り、`0x00/0x27` の塊で受ける** しかありません。つまり今のライブビューの接続(BLE → Wi-Fi → UDP 9004 の登録)が前提です。
- **最新の 45 件は「再生モード」なしでも読めます。** 古いページを読む・Pocket 3 で一覧が欠けないようにするには、先に `0x02/0x0C` `01 01 00 01` で再生モードに入ります。**再生モードに入るとライブビューは止まり(Pocket 4 はジンバルを畳む)、録画中なら録画が止まるとされます。** 試作は録画中は開けないようにしました。
- **Range(206)で続きから取れます。** Mimo の取り込みも約 1MB ずつの Range でした。Pocket 3 では HTTP で取った 20 本以上の元ファイルが SD カードの中身と SHA-256 で一致しています(OpenPocketCine の実測)。
- **Pocket 4 は本体に 107GB の保存領域があり、そこにある動画は `storage=1`。** microSD は `storage=0`。Pocket 3 は microSD だけで常に `storage=0`。外れたらもう一方で試せば足ります(OpenCine と同じ)。
- 速さ: DJI の公表は Pocket 4 + Wi-Fi 6 + Mimo で **最大 90MB/s**。独立した実測は見つかりませんでした。数十 MB/s 出れば、4K の 1 分(約 0.7〜1GB)が数十秒です。
- ライセンス: OpenCine / OpenPocketCine は Apache 2.0、Osmosis は MIT。どちらも app に入れてよい条件です(表示を付ける)。**信頼できて、ライセンスも合うと判断し、試作を作りました。**

### 調べたもの

| 出どころ | 中身 | ライセンス | 確かめた機種 | 信頼度 |
| --- | --- | --- | --- | --- |
| [OpenPocketCine handbook `protocol/media.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/35f51dc57277cef7a56e1504df415f716a9f98e2/handbook/src/content/docs/protocol/media.md) | `/v2` の形、サムネイル `MISC/THM/…/.scr`(JPEG)、一覧 `0x00/0x26`・`0x00/0x27`、再生モード `0x02/0x0C`、番号 1 = SD・2 = 本体、待ち時間(1 秒の静けさ・全体 12 秒) | Apache 2.0 | Pocket 3・Pocket 4 Pro・Nano ほか | 高 |
| [OpenPocketCine handbook `devices/pocket-3/media.md`](https://github.com/erik-sutton95/OpenPocketCine/blob/35f51dc57277cef7a56e1504df415f716a9f98e2/handbook/src/content/docs/devices/pocket-3/media.md) | HTTP で取った元ファイル 24〜25 本が Mimo の取り込み・SD カードの中身と **SHA-256 で一致**。どの転送も 206 の連続した Range で、ETag と全長が一貫。**パスの `/` を `%2F` にすると 404**。入れ子のパス(`DCIM/TIMELAPSE/…/TIMELAPSE_0001.DNG`)も取れた | Apache 2.0 | **Pocket 3(実測)** | 高 |
| [OpenCine `Sources/OpenCineDJI/MediaManifest+DJIWire.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e77b48bedc12f57e6be36a88e27c74007/Sources/OpenCineDJI/MediaManifest+DJIWire.swift) | 一覧の命令のバイト列(41 バイトの雛形、@4 番号、@10–13 カーソル)・きっかけ `4a040e10…`・塊の組み立て・CompositePack の読み方(パス・サムネイル・大きさ・秒・解像度・fps) | Apache 2.0 | Pocket 3 / 4 / 4 Pro(アプリで使用中) | 高 |
| [OpenCine `Sources/OpenCineCameraVocabulary/MediaManifest.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e77b48bedc12f57e6be36a88e27c74007/Sources/OpenCineCameraVocabulary/MediaManifest.swift)・[`DJIMediaHTTPSource.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e77b48bedc12f57e6be36a88e27c74007/Sources/OpenCineDJI/DJIMediaHTTPSource.swift) | `/v2` の URL の作り方(URLComponents)、storage の決め方(番号 → handle の bit `0x40000000` → Pocket 3 は 0)、**404 ならもう一方の storage で試す** | Apache 2.0 | 同上 | 高 |
| [OpenCine `Sources/OpenCineDJIApple/DjiAppleMediaService.swift`](https://github.com/erik-sutton95/OpenCine/blob/dd77b69e77b48bedc12f57e6be36a88e27c74007/Sources/OpenCineDJIApple/DjiAppleMediaService.swift)・`DjiAppleMediaLiveReturn.swift` | 順番: 再生モード(900ms × 3 回)→ SD を頼む → きっかけ → 本体を頼む → SD が空ならもう 1 回。閉じたら再生モードを抜けて `0x09/0xA8` | Apache 2.0 | 同上 | 高 |
| [Osmosis `MEDIA_PROTOCOL.md`](https://github.com/KonradIT/osmosis/blob/main/MEDIA_PROTOCOL.md)・`docs/01-protocol-map.md` | lighttpd/1.4.55、`/v2` 以外は切断、HEAD と Range 可。**Pocket 4 は本体の保存領域 = `storage=1`、handle は `0x40100000` から 0x40 刻み、代理ファイル(.LRF)は一覧に無い、カードが無くても保存先が 2 つの機種、再生モードは 2 回目で入ることがある、再生モード中はジンバルを畳む。** 再生モードは返事ではなく `0x02/0x80` bit 30 で確かめる。入った直後は保存先がまだ読めず約 1.7 秒待つ。**ジンバル機は再生モード中は撮らない**。Pocket 3 は `0x02/0x0C` に E0(別の命令 `0x01/0x01` で入る)。前の接続のセッションが残ると一覧に答えないことがある | MIT | Nano・Action 5 Pro / Xtra(実測)、Pocket 3 / 4(表に記載) | 中〜高(Pocket 4 の行は短い記述) |
| CineD・heliguy・DJI の販売ページ | Pocket 4: Wi-Fi 6、Mimo への無線転送 **最大 90MB/s**、USB 3.1 で最大 800MB/s、本体 107GB + microSD | 記事 | Pocket 4 | 参考(公表値) |
| [node-osmo](https://github.com/datagutt/node-osmo)・[osmo-live](https://github.com/KevinCowleys/osmo-live)・[lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) | BLE と RTMP 配信だけ。**メディアの一覧・HTTP の取り込みは扱っていない**(ファイル構成で確認) | MIT | Pocket 3 | 該当なし |
| [dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) | ドローン向けの DUML の辞書。Osmo の HTTP `/v2` についての記述は無い | GPL-3.0(使わない) | 古いドローン | 該当なし |

### 命令とリクエストの形

```text
(ライブビューと同じ接続: BLE ペアリング → カメラの Wi-Fi → UDP 9004 のハンドシェイクと登録。登録 0x00/0x88 は 1 秒ごと)

再生モードに入る   0x02/0x0C  受け手 0x01  flags 0x40  [01 01 00 01]   (返事 [00] は「受け取った」だけ)
                  確かめ: 0x02/0x80 の u32-LE @0 の bit 30 (0x40000000) = 再生モード中
                  入らなければ 900ms ごとに 3 回まで。Pocket 4 は 2 回目で入ることがある。Pocket 3 は E0
                  入ったら約 1.7 秒待つ(保存先がまだ読めず、空の答えになるため)
抜ける            0x02/0x0C  [01 01 00 00]

一覧(最新 45 件)  0x00/0x26  受け手 0x01  flags 0x40
  SD    : 4A 00 2A 10 | 01 00 00 00 00 00 | 01 00 00 00 | 2D 00 0D 01 00 | FF×8 | 00 01 00×7 | 00×5
          (@4 = 番号 1、@10–13 = カーソル 0x00000001)
  きっかけ: 4A 04 0E 10 01 00 00 00 00 00 01 00 00 00
  本体  : 雛形の @4 = 02、@10–13 = 0x40000001
答え              0x00/0x27  payload = [4A][種類][..][..][番号][..][seq u16-LE][..][..] + 塊
                  種類 04 = 始まり、01 = データ、03 = 終わり。番号ごとに、頭 10 バイトを外して届いた順につなぐ
                  (4A 01 で始まる別の通知があるので、必ず 0x00/0x27 で選ぶ)
                  始まりだけでデータが無い = その保存先は空
中身(CompositePack): [u32-LE このページの件数] + 記録 × 件数
  0d <len> "<名前>.<拡張子>"                 ← 拡張子はここだけ
  1a <全長> 00 00 00 01 "DCIM/DJI_001/DJI_<YYYYMMDDHHMMSS>_<NNNN>_D"   ← 媒体パス(拡張子なし)
  1a <全長> 00 00 00 02 "MISC/THM/DJI_001/…"  ← サムネイル(+ ".scr")
  印 [03 ff] 19 06(T = 19 06 の位置): T-14 大きさ u32、T-10 handle u32、T-6 秒 u16、T-4 fps 番号、T-3 解像度番号

ファイル          GET http://192.168.2.1/v2?storage=<0|1>&path=DCIM/DJI_001/DJI_20261031123456_0012_D.MP4
                  (/ はそのまま。%2F は 404)。Range: bytes=<n>-  → 206 + Content-Range。ETag あり
サムネイル        GET http://192.168.2.1/v2?storage=<0|1>&path=MISC/THM/DJI_001/DJI_…_D.scr  → JPEG
storage           SD(番号 1 の答え)= 0、本体(番号 2)= 1。番号が無いときは handle の bit 0x40000000 → 1。
                  Pocket 3 は常に 0。404 ならもう一方で試す
```

### 答え(聞かれたことごとに)

| 質問 | 答え | 信頼度 |
| --- | --- | --- |
| HTTP のアドレス・ポート | `192.168.2.1:80`(iPhone は DHCP で 192.168.2.x)。192.168.42.1 などではない | 高 |
| 一覧・サムネイル・元ファイルのエンドポイント | 一覧は HTTP に無い(DUML `0x00/0x26`)。サムネイルと元ファイルはどちらも `/v2?storage=&path=` | 高 |
| 先に要る命令・トークン | HTTP に認証は無い。一覧にはデータリンクの登録(今のライブビューと同じ)が要り、確実にするなら再生モード `0x02/0x0C` | 高 |
| 録画を止める必要 | ファイルは録画が止まって閉じるまで取れない。**再生モードに入ると録画が止まるとされる**(Osmosis: ジンバル機は再生モード中は撮らない)。Action 4 は撮影中の一覧に `d8`、Pocket 3 は撮影中だと一覧が欠ける。→ 止めてから取り込む | 中 |
| ファイルの形式 | Pocket 3 の実物: MP4。HEVC 10-bit(HLG / D-Log M、4K・2.7K・3K 正方形)、互換モードは H.264 8-bit。音は AAC 48kHz(モノ/ステレオ)。スローモーションは音なしで、別に AAC のファイル。`.LRF` は 1280×720 の H.264 のプレビュー。Pocket 4: パスは `DCIM/DJI_001/DJI_…_D.MP4`、代理ファイルは一覧に無い。中身のコーデックの実物の記録は無い(録画設定どおりと考えられる) | Pocket 3 高、Pocket 4 中 |
| 速さ | Pocket 4 の公表値は最大 90MB/s(Wi-Fi 6・Mimo)。実測の記録なし。Osmo Nano では SD から 760MB 付近で転送が切れ、Range で続きを取る必要があった | 中 |
| DJI Mimo のやり方 | Mimo のアルバムも同じ `/v2` を約 1MB ずつの Range で取っている(Pocket 3 の通信の記録)。一覧の命令も Mimo と同じバイト列。再生モード + 1 秒ごとの登録で保つ | 高(Pocket 3) |

### 試作(`Sources/Osmo/OsmoMediaBrowser.swift`)

- `OsmoMediaLibrary`(`OsmoLiveMonitor.media`): データリンクが開いたら `attach`、切断で `detach`。`0x00/0x27` はデータリンクのキューの上で `OsmoMediaChunkCollector` に直接入れる(届いた順を崩さないため)。`0x02/0x80`・`0x02/0x0C` は MainActor で見る。
- 一覧: 再生モードに入る(bit 30 か返事 `00` で「入った」)→ 1.7 秒待つ → SD・きっかけ・本体 → 終わりの印を待つ(全体 12 秒まで)→ CompositePack を読み、**動画(MP4/MOV)だけを新しい順** に。サムネイル・長さ・解像度・fps・大きさを出す。件数より読めた数が少ないと「一部が届きませんでした」。
- 取り込み: `URLSession` の代理で、届いた分を **そのまま一時フォルダーの `.part` に書く(メモリにためない)**。切れたら `Range: bytes=<今の大きさ>-` と `If-Range: <ETag>` で続きから(6 回まで。進んでいれば数え直し)。206 の開始位置が違えば失敗、200 なら最初から書き直す。最初の 1 バイトの前に 404 なら、もう一方の storage で。モバイル通信は使わない(`allowsCellularAccess = false`)。「やめる」でも `.part` は残り、同じ動画をタップすると続きから。2 日より前の残りは消す。取り込み中は自動ロックを止める。
- 終わったら `.part` を元の名前(`DJI_….MP4`)に変え、ライブビュー画面の `onUse` → `startLocalImport(… deleteSourcesAfter: true)` に渡す(iPhone で録ったときと同じ道)。
- 画面: ライブビュー画面の「カメラの動画を取り込む(本来の画質)」の欄。カメラの録画を止めた直後は「今撮った動画を取り込む」(一覧を読んで一番新しい動画をすぐ取り込む)。**カメラ・iPhone のどちらかで録画中は開けない。** 画面を閉じると再生モードを抜け、ライブビューを頼み直す。開いているあいだは、ライブビューの止まり検知(キーフレームの頼み直し)を止める。編集画面から開いたとき(`onUse` があるとき)だけ出す。
- `project.yml` の osmo-live の印の中に `NSAppTransportSecurity` → `NSAllowsLocalNetworking: true` を足した(暗号化なしの HTTP を 192.168.2.1 に出すため。OpenPocketCine も同じ)。ローカルネットワークの説明文にも「動画を取り込む」を足した。
- ライセンス表示: `docs/licenses/README.md` に Osmosis(MIT)を足し、本文を `docs/licenses/Osmosis-LICENSE.txt` に置いた。
- 入れていないもの: 46 件目より古いページ(ページ送り)、写真、削除・お気に入り、プレビュー再生、Pocket 3 の別の再生モード命令 `0x01/0x01`(Pocket 3 は再生モードなしで最新 45 件を読む)、複数本まとめての取り込み。

### 実機で確かめること(取り込み)

**すべて未検証です。** カメラを Video モードにして、何本か短く撮ってから試してください。ログ(「ログを共有」)の `media:` の行が手がかりです。

1. **ビルドが通るか**(`OSMO_LIVE` を on にした TestFlight)。
2. 編集画面の「追加」→「Osmo Pocket で撮る(実験)」でライブビューまでつなぎ、「カメラの動画を取り込む」が出るか。
3. 開くと、カメラ本体が再生モードになり(ジンバルを畳む)、ログに `media: camera reports playback ON` が出るか。出なければ `media: reply 0x02/0x0C …` の値を送ってください。
4. 一覧が出るか。ログの `media: answer sd … B, internal … B` と `… files, … videos` の数。**本体(107GB)に撮った動画と microSD に撮った動画の両方が出るか**(Pocket 4)。
5. 日時・長さ・解像度(3840×2160 など)・fps・大きさが、カメラ本体のアルバムの表示と合うか。サムネイルが出るか。
6. 1 本タップして取り込めるか。**速さ(MB/s)** を教えてください(画面の表示)。1GB 前後のファイルで、かかった時間も。
7. 取り込んだ動画がプロジェクトに入り、**画質が本来のまま(4K・10-bit なら 10-bit)** か。Mimo で取り込んだものと見比べて。大きさ(バイト数)がカメラ本体の表示と一致するか。
8. 途中で「やめる」→ もう一度タップで **続きから** 進むか(ログ `download … from <途中のバイト数> B`)。
9. 途中でアプリを裏に回す・カメラから離れるなどで切れたとき、戻ってタップすると続きから取れるか。
10. 一覧の画面を閉じたら、カメラが再生モードを抜けて(`camera reports playback off`)ライブビューが戻るか。戻らなければ時間とログを。
11. カメラ本体で録画を止めた直後に「今撮った動画を取り込む」で、**今撮った動画** が自動で取り込まれるか(1 つ前の動画にならないか)。
12. 録画中は「カメラの動画を取り込む」が押せないか。
13. 閉じてもう一度開いたときも一覧が読めるか。一覧に答えないときは、カメラの電源を入れ直して試す(前の接続が残ると答えないことがある)。
14. (あれば)Pocket 3 でも。Pocket 3 は再生モードに入らず(ログ `playback not confirmed`)最新 45 件を読みます。一覧が欠けないか。
