# 画面の参照画像(スナップショット)

`UITests/` のテストが描いた画面の「正しい見た目」です。テストは同じ条件で画面を描き、ここにある PNG と画素ごとに比べます。

- フォルダはテストファイルごと(例: `TeleprompterOverlayTests/long-script-phone.png`)
- 描く大きさ・余白(セーフエリア)・倍率(2x)はテストの中で固定しているので、シミュレータの機種が変わっても同じ大きさになります
- 少しのにじみは許します(1 画素の差が 24/255 以下は同じ、違う画素が 0.5% 以下なら合格)

## 参照画像の更新のしかた

見た目をわざと変えたときは、次のどれかで記録し直してコミットします。

1. **GitHub Actions で記録し直す(おすすめ)**
   Actions → 「UI tests (simulator)」→ Run workflow → ブランチを選び、`record` にチェックして実行。
   全部の参照画像を描き直して、そのブランチにコミットします。差分(画像)はプルリクエストで確かめてください。
2. **参照画像が無いテストを足したとき**
   プルリクエストで走ると、無い分だけ記録してプルリクエストのブランチにコミットします(このときそのテストは合格扱い)。
3. **手元の Mac で記録し直す**

   ```bash
   xcodegen generate --spec project.yml
   TEST_RUNNER_SNAPSHOT_RECORD=1 xcodebuild test -project VideoEditor.xcodeproj -scheme VideoEditorUITests \
     -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
   ```

   特定の画像だけ直すなら、その PNG を消してからふつうに `xcodebuild test` を走らせても記録されます。
   参照画像は CI と同じ Xcode(シミュレータの iOS)で記録してください。iOS が違うと文字の描き方が変わって全部ずれることがあります。

## 失敗したとき

ワークフローの Artifacts「failed-snapshots」に、テストごとに次の画像が入ります。

| ファイル | 中身 |
| --- | --- |
| `<名前>.actual.png` | 今回描いた画面 |
| `<名前>.reference.png` | 参照画像 |
| `<名前>.diff.png` | 違う画素を赤、同じ画素を暗くしたもの |
| `<名前>.unsettled.png` | 3 秒たっても描き直しが止まらなかったときの最後の画面 |

xcresult(Artifacts「xcresult」)にも同じ画像が添付されています。
