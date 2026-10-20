# 1.5 usability pass — contract between parallel teams

Rules: iOS 18 target, Swift 5 mode, CI Xcode 26; nobody compiles locally — re-read for compile errors. Never write `$binding.animation.x`; keep arithmetic expressions short with explicit types. Japanese UI. Edit ONLY your files. Another agent is concurrently editing SubtitleSegmenter.swift, SubtitleRenderer.swift, CloudTranscriber.swift, SubtitlePolisher.swift — nobody else touches them.

Glossary (use these exact labels everywhere): 書き出し (export video), 字幕, BGM, 分割, 削除, 元に戻す, 色ごと調整 (HSL), カラーLUT読込, 明るさグラフ (scopes), 音のずらし (J/L cut), 人物を自動で中央に (reframe), 動きをつける (keyframes), ゆっくりズーム (Ken Burns), 動きに追従 (tracking), 重ね方 (blend), なめらか変速 (speed curve), 全体の仕上げ (documentary panel), お決まりパーツ (format kits), 前回と比較, 表紙を作る (cover), ロゴ・透かし, 目印 (markers), AI読み上げ, 動画から音を抽出, 写真を立体に, つなぎ効果 (transitions), 登場の動き (text/clip in-out animation), 静止画にする (freeze), 画質アップ (enhance), 別の端末へ送る (project package export), プロジェクトを受け取る (package import).

## Team B — Timeline & player (files: TimelineView.swift, TimelineTrackViews.swift, TimelineThumbnailCache.swift, Engine/PlayerController.swift, Model/MediaStore.swift (thumbnail generator caching only), Model/EditorSelection.swift (zoom limits only))
Provides:
```swift
// PlayerController
func scrub(to seconds: Double)        // chase seek with 0.1 s tolerance, coalesced; used while dragging
func endScrub(at seconds: Double)     // final exact seek
func beginInteraction()                // suspend composition rebuilds (counter)
func endInteraction()                  // resume; flushes one pending update(with:) if the snapshot changed
// update(with:) ignores changes that do not affect rendering (markers, cover, clip names)

// TimelineView
enum TimelineAddKind { case media, text, subtitle, overlay, bgm, narration }
init(project:player:history:timeline:selection:onAdd: @escaping (TimelineAddKind) -> Void = { _ in })
static func preferredHeight(for project: EditorProject) -> CGFloat   // only tracks with content + ruler + video + one 32pt "+" row
```
Implements: chase scrubbing; beginInteraction/endInteraction around trims, reorders and moves; snapping (playhead, clip edges, markers, other item edges; 8 pt threshold; light haptic; 1 pt yellow guide); 44 pt hit areas for handles; collapse empty tracks into one "+" row whose menu calls onAdd; left track icon chips; stronger selection frame + live duration badge; haptics at trim limits; momentum decay 0.998^ms; time bubble over the playhead while dragging; dynamic zoom-out limit; thumbnail generator reuse; a "+" tile after the last clip calling onAdd(.media); one-time hint 「長押しで並べ替え・端をドラッグで長さ調整」 (UserDefaults flag).

## Team A1 — Editor shell (files: ContentView.swift, EditorToolbar.swift, EditorPanels.swift)
- Regroup toolbars per the proposal below (≤ 9 primary items + 「その他」, using a new `EditorToolItem` group kind that opens a second-level row with a ‹ back). Labels from the glossary. 削除 last. Hide items that do not apply (still vs video) instead of disabling; when an item is disabled, tapping shows a toast with the reason.
- Toast: non-blocking overlay (auto-hide 2 s, optional 「元に戻す」 button calling history.undo). Use for success/cancel messages; keep alerts only for errors. Success/warning haptics.
- Split: feedback toast 「分割しました」; if the playhead is not on the clip show 「再生位置をクリップの上に合わせてください」.
- Delete/duplicate/auto actions: toast with undo.
- Layout: when a panel is open, hide the full timeline and show a compact 44 pt scrub bar (Slider bound via player.scrub/endScrub) so the preview keeps ≥ 40% height; cap panel height at min(panel.height, geo height × 0.38). Timeline height = TimelineView.preferredHeight(for:). Pass onAdd to TimelineView, routing each TimelineAddKind to the existing picker/panel.
- Extract the transport row into its own View struct so `player.currentTime` changes don't re-render ContentView; show time with tenths while paused (0:05.2), 15 pt monospaced.
- Top bar: replace ✕ with 「‹ 一覧」; move 「このプロジェクトを空にする」 into その他 → 設定 section; 44 pt tap targets for top-bar buttons and the timeline "+" button (anchor it to the video track per TimelineView metrics if you keep it; Team B also adds a "+" tile).
- 追加 accepts videos and photos (photos become still clips), label 「動画・写真を追加」.
- Panels: add a ✕ 「やめる」 (undo back to the snapshot recorded when the panel opened) and keep ✓; put the target in the title (「速度 – クリップ2」). EditorChip and color dots: 44 pt hit areas without changing visuals. Toolbar labels 12 pt; disabled opacity 0.45; left-aligned toolbar.
- Narration 「聞きやすくする」 asks for confirmation like the root one; remove "LUFS" from user-facing text.
Proposed toolbars: Root: 動画・写真を追加 | 編集 | BGM | 文字 (テキスト / 字幕 / 自動字幕 / 名前テロップ / 章タイトル) | ステッカー | 重ねる | 録音 (ナレーション録音 / AI読み上げ / 動画から音を抽出) | 比率 | おまかせ (おまかせ編集 / おまかせテンプレ / 無音カット / 音量そろえ / AI台本 / スライドショー); その他: 全体の仕上げ, 手書き, 目印, ロゴ・透かし, お決まりパーツ, 表紙を作る, 前回と比較, このプロジェクトを空にする. Clip: 分割 | 速度 (速度 / なめらか変速) | 音量 | フィルタ | 色調整 (自動補正 / 色調整 / 色ごと調整 / 色合わせ / カラーLUT読込 / 明るさグラフ) | つなぎ効果 | 登場の動き | 切り抜き・回転 | 削除; その他: 複製, 置き換え, 逆再生, 静止画にする, 音の効果, 音のずらし, ビートに合わせる, 手ぶれ補正, 画質アップ, 人物を自動で中央に, マスク, 写真を立体に (stills only), マルチカメラ, パーツとして保存, 詳細設定. Overlay: 位置・サイズ | 動きをつける | 動きに追従 | 重ね方 | フィルタ | 音量 | 速度 | 複製 | 削除; その他: マスク, ゆっくりズーム, 写真を立体に. Text: 文字・スタイル | 登場の動き | 位置・サイズ | 動きをつける | 動きに追従 | 複製 | 削除. Subtitle: 文字を直す | 全字幕のスタイル | 字幕デザイン | 自動字幕 | 削除. BGM: 音量 | 曲を変更 | 削除. Narration: 音量 | 音の効果 | 聞きやすくする | 削除. Drawing: 色・太さ | 表示する時間 | 削除. Marker: 名前 | 色・種類 | 削除.

## Team A2 — Preview interaction (files: PreviewGestureOverlay.swift, PreviewView.swift)
- Tap on the preview hit-tests text clips, stickers and overlays active at the current time (topmost first) and sets selection; tap on empty video selects the clip under the playhead; second tap on empty area clears selection.
- Wrap drags/pinches with player.beginInteraction()/endInteraction(); while dragging draw the element's live position as a SwiftUI overlay (the dashed frame + a semi-transparent text/thumbnail proxy) so it visibly moves.
- One-time coach mark 「ドラッグで移動・2本指で拡大/回転」; badges ≥ 14 pt icons.
- PreviewView: rebuild spinner only after 400 ms, small, in a corner; keep the last frame visible while rebuilding (snapshot via AVPlayerItemVideoOutput or the layer's last pixel buffer shown as an image under the layer).

## Team A3 — Panels content (files: ClipFXPanels.swift, OverlayPanels.swift, TextPanels.swift, MaskPanels.swift, DocumentaryPanels.swift, AudioToolPanels.swift)
- Apply the glossary to every visible string; add one-line plain explanations under jargon-heavy controls; 44 pt hit areas for small buttons/color dots/menus; remove "LUFS/LU/dBFS" from user text (use 小さめ/ちょうどいい/大きすぎ); add 「リセット」 where a panel has sliders and none exists.

## Team C — Secondary screens (files: SubtitleEditorView.swift, ExportView.swift, ExportProgressBanner.swift, ProjectLibraryView.swift, TranscriptionSettingsView.swift, CompareView.swift, MulticamEditorView.swift, ClipEditorView.swift, AudioSettingsView.swift, CoverMakerView.swift, AutoEditViews.swift, ScriptWriterView.swift, Model/Models.swift (SubtitleDisplayMode display names only))
- Implement the secondary-screens audit: SubtitleEditorView restructure (list first when cues exist; 「自動で字幕を作る」 card first when empty; advanced items in 「詳細設定」), ExportView restructure (4 use-case presets with おすすめ badge, one-line summary with space check, sticky bottom 「書き出す(約 120MB・写真に保存)」 button, details in 「詳細設定」, 「その他の書き出し」 link), remaining time in progress and banner, OS-aware lock message, close-confirmation during transcription, action-first error messages, 別の端末へ送る / プロジェクトを受け取る wording, plain-language export settings, LUFS wording in CompareView, MulticamEditorView offset explanation, TranscriptionSettingsView: 「文字起こしの方式」 wording, remove provider row, API key explanation, diagnostics collapsed under 「サポート用の情報」, relative dates and empty-state text in the library, SubtitleDisplayMode names 原文 / 訳文 / 両方, translation toggles 訳文を使う / 2言語.
