# 第三者のライセンス(Osmo Pocket の実験)

`Sources/Osmo/` の一部は、次のオープンソースから移植・改変しています。

| 元 | ライセンス | 使った部分 |
| --- | --- | --- |
| [OpenCine](https://github.com/erik-sutton95/OpenCine)(commit `dd77b69e77b48bedc12f57e6be36a88e27c74007`) | Apache License 2.0 | DUML フレーム・CRC・UDP の包み・命令のバイト列・映像の組み立て(`OsmoDUML.swift`、`OsmoVideoDepacketizer.swift`)、カメラの動画の一覧の読み方と `/v2` の URL(`OsmoMediaBrowser.swift`)。Bluetooth・Wi-Fi・データリンク・復号は手順を参考に書き直し |
| [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine)(commit `35f51dc57277cef7a56e1504df415f716a9f98e2`) | Apache License 2.0 | プロトコルの資料(`handbook/`)。`docs/OsmoPocket.md` の説明のもと |
| [Osmosis](https://github.com/KonradIT/osmosis)(main、2026-10-31 に参照) | MIT License | `MEDIA_PROTOCOL.md` の資料(機種ごとの保存先と `storage` の値、再生モードの確かめ方、待ち時間)。`OsmoMediaBrowser.swift` の説明のもと。コードは移していない |
| [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine)(commit `d2851068d2176fb9ef7d498a05453e2397c4fe83`・`137433b776c27c8ec5066c7f40a1ee3a86441981`、handbook は main を 2026-10-31 に参照) | Apache License 2.0 | RTMP の受け方(`RTMPIngest.swift`・`MultiviewRTMPServer.swift` を参考に `OsmoRTMPServer.swift` を書き直し)、Pocket 4 Pro の RTMP 設定(版 01 の JSON)と Pocket 3 の記録(`OsmoRTMPLink.swift`) |
| [node-osmo](https://github.com/datagutt/node-osmo)(main、2026-10-31 に参照) | MIT License(Copyright (c) 2024 Thomas Lekanger) | RTMP 設定の 9 バイトの読み方(解像度・ビットレート・fps)。`OsmoRTMPLink.swift` の説明のもと。コードは移していない |
| [lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble)(main、2026-10-31 に参照) | MIT License(Copyright (c) 2026 Yigit Konur) | Pocket 3 の BLE 手順の確認(`PROTOCOL.md`)。コードは移していない |

- ライセンスの本文: [OpenCine-LICENSE.txt](OpenCine-LICENSE.txt)(OpenPocketCine も同じ本文)
- Osmosis のライセンスの本文: [Osmosis-LICENSE.txt](Osmosis-LICENSE.txt)(Copyright (c) 2026 Konrad Iturbe)
- 元の NOTICE: [OpenCine-NOTICE.txt](OpenCine-NOTICE.txt)、[OpenPocketCine-NOTICE.txt](OpenPocketCine-NOTICE.txt)
- 改変したファイルには、先頭のコメントに元のファイル名と「変更点」を書いています(Apache 2.0 第 4 条)

Copyright 2026 Erik Sutton and OpenCine contributors / OpenPocketCine contributors.

この app は DJI と関係がなく、DJI の承認も受けていません。「DJI」「Osmo」「Osmo Pocket」「Mimo」は
SZ DJI Technology Co., Ltd. の商標で、機種を示すためだけに使っています。DJI の SDK や非公開の資料は使っていません。

実験を製品に入れる(OSMO_LIVE を on にして配る)ときは、アプリの中にもこのお知らせ(ライセンス表示)を出してください。
