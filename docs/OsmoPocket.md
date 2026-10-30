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
| Pocket 4 / 4 Pro | HEVC(H.265 Main) | 1280×720、約 25fps、約 4Mbps。録画の設定とは別 |
| Pocket 3 | H.264 が観測されている | 720p、約 25fps |

- 1 枚は `00 00 01 ff` + 長さ(u32 リトルエンディアン)+ 8 バイトの 16 バイトのヘッダーで始まります。そのあとが Annex-B です。
- 1 枚は複数のパケットに分かれます。パケット番号は 8 ずつ進みます。欠けたらその 1 枚を捨てます。
- 符号化方式はパラメーターセット(HEVC の VPS/SPS/PPS、H.264 の SPS/PPS)だけで決めます。
- **定期的なキーフレームはありません。** `0x09/0xA8` がキーフレームの要求です。毎秒送ると逆にキーフレームが届かなくなります。止まったときに、数秒あけて 1 回だけ送ります。
- Pocket 4 のキーフレームは IDR ではなく BLA(NAL 種類 16)のことが多いです。
- ライブビューを止める命令はありません。切断してもカメラは送り続けます。

### 7. ファイルの取り込み(今後)

カメラの Wi-Fi の上で `GET http://192.168.2.1/v2?storage={0|1}&path=…` でファイルを取れます。一覧は DUML の `0x00/0x26`・`0x00/0x27` です。今回は作っていません。

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
