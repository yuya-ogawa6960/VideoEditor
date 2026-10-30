# 第三者のライセンス(Osmo Pocket の実験)

`Sources/Osmo/` の一部は、次のオープンソースから移植・改変しています。

| 元 | ライセンス | 使った部分 |
| --- | --- | --- |
| [OpenCine](https://github.com/erik-sutton95/OpenCine)(commit `dd77b69e77b48bedc12f57e6be36a88e27c74007`) | Apache License 2.0 | DUML フレーム・CRC・UDP の包み・命令のバイト列・映像の組み立て(`OsmoDUML.swift`、`OsmoVideoDepacketizer.swift`)。Bluetooth・Wi-Fi・データリンク・復号は手順を参考に書き直し |
| [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine)(commit `35f51dc57277cef7a56e1504df415f716a9f98e2`) | Apache License 2.0 | プロトコルの資料(`handbook/`)。`docs/OsmoPocket.md` の説明のもと |

- ライセンスの本文: [OpenCine-LICENSE.txt](OpenCine-LICENSE.txt)(OpenPocketCine も同じ本文)
- 元の NOTICE: [OpenCine-NOTICE.txt](OpenCine-NOTICE.txt)、[OpenPocketCine-NOTICE.txt](OpenPocketCine-NOTICE.txt)
- 改変したファイルには、先頭のコメントに元のファイル名と「変更点」を書いています(Apache 2.0 第 4 条)

Copyright 2026 Erik Sutton and OpenCine contributors / OpenPocketCine contributors.

この app は DJI と関係がなく、DJI の承認も受けていません。「DJI」「Osmo」「Osmo Pocket」「Mimo」は
SZ DJI Technology Co., Ltd. の商標で、機種を示すためだけに使っています。DJI の SDK や非公開の資料は使っていません。

実験を製品に入れる(OSMO_LIVE を on にして配る)ときは、アプリの中にもこのお知らせ(ライセンス表示)を出してください。
