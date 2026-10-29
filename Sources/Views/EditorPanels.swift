import SwiftUI
import UIKit
import Combine
import Observation

// =====================================================================
// CapCut 風の小さな下部パネル(ツールバーの位置に差し替えて表示する)
// =====================================================================

/// 下部パネルの種類
enum EditorPanel: Hashable {
    case speed(UUID)
    case volume(UUID)
    case filter(UUID)
    case textEdit(UUID)
    case subtitleStyle
    case aspect
    case bgmVolume
    /// ドキュメンタリー風の全体演出
    case documentary
    /// 章タイトル 1 件の編集(+一覧)
    case titleCard(UUID)
    /// テロップ 1 件の編集(+一覧)
    case lowerThird(UUID)
    /// クリップの J カット / L カット(音声の先出し・後残し)
    case jlCut(UUID)
    /// クリップの色調整(露出・色温度など)
    case colorAdjust(UUID)
    /// オーバーレイの配置(プリセット・位置・サイズ・不透明度・フェード)
    case overlayPlacement(UUID)
    /// オーバーレイのケン・バーンズ(ゆっくりしたズーム / パン)
    case overlayKenBurns(UUID)
    /// オーバーレイ(動画)の音量
    case overlayVolume(UUID)
    /// オーバーレイ(動画)の速度
    case overlaySpeed(UUID)
    /// オーバーレイのフィルタ
    case overlayFilter(UUID)
    /// ナレーション 1 件の音量
    case narrationVolume(UUID)
    /// ナレーションの録音(ルートツールバーから開く)
    case narrationRecord

    // ---- 第3弾: クリップ ----
    /// スリップ(長さはそのままで、元の動画のどこを使うかをずらす)
    case slip(UUID)
    /// クリップの終わりから次のクリップへのトランジション
    case transition(UUID)
    /// クリップのイン・アウト アニメーション
    case clipAnimation(UUID)
    /// 切り抜き / 回転 / 反転 / ズーム
    case geometry(UUID)
    /// 速度カーブ
    case speedCurve(UUID)
    /// 音声効果(EQ・ピッチ・ボイス)
    case audioEffects(UUID)
    /// ビート検出
    case beatDetect(UUID)
    /// HSL(色相帯ごとの調整)
    case hsl(UUID)
    /// LUT(.cube)
    case lut(UUID)
    /// 色合わせ(別クリップを基準に色を寄せる)
    case colorMatch(UUID)

    // ---- 第3弾: テキスト・ステッカー ----
    /// テキストレイヤー 1 件の文字・スタイル
    case textStyle(UUID)
    /// テキストレイヤーのアニメーション
    case textAnimation(UUID)
    /// テキストレイヤーの配置(位置・大きさ・回転)
    case textPlacement(UUID)
    /// テキストレイヤーのキーフレーム
    case textKeyframes(UUID)
    /// 絵文字ステッカーの選択(ルート)
    case sticker
    /// カラーの画面(単色の静止画クリップ)を差し込む
    case colorScreen

    // ---- 第3弾: オーバーレイ ----
    case overlayKeyframes(UUID)
    case overlayBlend(UUID)
    case overlayTransition(UUID)
    case overlayOpacity(UUID)

    // ---- 第3弾: ナレーション ----
    case narrationEffects(UUID)

    // ---- 第3弾: 手書き ----
    /// 新しい手書きを描いている最中(プレビューにキャンバスを重ねる)
    case drawingCanvas
    case drawingStyle(UUID)
    case drawingTiming(UUID)

    // ---- 第3弾: マーカー ----
    case markerName(UUID)
    case markerKind(UUID)

    // ---- 第3弾: 字幕テンプレート ----
    case captionTemplate

    // ---- 第3弾: ルート ----
    case watermark
    case formatKit
    case textToSpeech

    // ---- 第4弾: クリップ ----
    /// マスク(形・大きさ・ぼかし。中心はプレビュー上でドラッグ)
    case mask(UUID)
    /// 自動リフレーム(人物追尾の解析と設定)
    case autoReframe(UUID)
    /// 手ぶれ補正(解析と強さ)
    case stabilize(UUID)
    /// 画質(ノイズ除去・美肌・簡易高画質化)
    case enhance(UUID)
    /// 静止画クリップの 3D ズーム(奥行き視差)
    case parallax(UUID)
    /// 人物・被写体だけパッと光らせる
    case subjectFlash(UUID)
    /// レタッチ(小顔・目・メイク・体型)
    case retouch(UUID)
    /// メインクリップのキーフレーム(位置・大きさ・回転・不透明度。ClipKeyframePanel.swift)
    case clipKeyframes(UUID)

    // ---- 第4弾: オーバーレイ ----
    case overlayMask(UUID)
    case overlayParallax(UUID)
    /// 背景を消す / クロマキー(BackgroundRemovalPanel.swift)。クリップ用とオーバーレイ用
    case backgroundRemoval(UUID)
    case overlayBackgroundRemoval(UUID)

    // ---- 第4弾: トラッキング(プレビューで対象を囲む → キーフレーム) ----
    case textTracking(UUID)
    case overlayTracking(UUID)

    /// モザイク / ぼかしの種類・形・強さ・大きさ
    case mosaic(UUID)

    /// 中だるみチェックの結果
    case pacing

    // ---- 第4弾: ルート ----
    /// おまかせ編集のテンプレート一覧
    case autoEditTemplates
    /// 吹き替え(キャプションを訳して声にする。DubbingPanel.swift)
    case dubbing
    /// 内蔵の効果音(SoundEffectPanel.swift)
    case soundEffects
    /// 映像エフェクトを選んで追加する(ルート。VideoEffectPanel.swift)
    case videoEffectAdd
    /// 選んだ映像エフェクトの種類・強さ
    case videoEffect(UUID)

    var title: String {
        switch self {
        case .speed: return String(localized: "速度・デュレーション")
        case .volume: return String(localized: "ボリューム")
        case .filter: return String(localized: "カラープリセット")
        case .textEdit: return String(localized: "文字を直す")
        case .subtitleStyle: return String(localized: "キャプションのデザイン")
        case .aspect: return String(localized: "比率")
        case .bgmVolume: return String(localized: "BGM の音量")
        case .documentary: return String(localized: "全体の仕上げ")
        case .titleCard: return String(localized: "章タイトル")
        case .lowerThird: return String(localized: "名前テロップ")
        case .jlCut: return String(localized: "J/Lカット")
        case .colorAdjust: return String(localized: "カラー補正")
        case .overlayPlacement: return String(localized: "位置・サイズ")
        case .overlayKenBurns: return String(localized: "ズーム・パン")
        case .overlayVolume: return String(localized: "ボリューム")
        case .overlaySpeed: return String(localized: "速度・デュレーション")
        case .overlayFilter: return String(localized: "カラープリセット")
        case .narrationVolume: return String(localized: "ボリューム")
        case .narrationRecord: return String(localized: "ボイスオーバー録音")
        case .slip: return String(localized: "スリップ")
        case .transition: return String(localized: "ビデオトランジション")
        case .clipAnimation: return String(localized: "アニメーション")
        case .geometry: return String(localized: "モーション・クロップ")
        case .speedCurve: return String(localized: "タイムリマップ")
        case .audioEffects: return String(localized: "オーディオエフェクト")
        case .beatDetect: return String(localized: "ビートに合わせる")
        case .hsl: return String(localized: "HSL セカンダリ")
        case .lut: return String(localized: "LUT")
        case .colorMatch: return String(localized: "カラーマッチ")
        case .textStyle: return String(localized: "文字・スタイル")
        case .textAnimation: return String(localized: "アニメーション")
        case .textPlacement: return String(localized: "位置・サイズ")
        case .textKeyframes: return String(localized: "キーフレーム")
        case .sticker: return String(localized: "ステッカー")
        case .colorScreen: return String(localized: "カラーの画面")
        case .overlayKeyframes: return String(localized: "キーフレーム")
        case .overlayBlend: return String(localized: "描画モード")
        case .overlayTransition: return String(localized: "ビデオトランジション")
        case .overlayOpacity: return String(localized: "不透明度")
        case .narrationEffects: return String(localized: "オーディオエフェクト")
        case .drawingCanvas: return String(localized: "手書き")
        case .drawingStyle: return String(localized: "色・太さ")
        case .drawingTiming: return String(localized: "表示する時間")
        case .markerName: return String(localized: "マーカーの名前")
        case .markerKind: return String(localized: "色・種類")
        case .captionTemplate: return String(localized: "キャプションのデザイン")
        case .watermark: return String(localized: "ロゴ・透かし")
        case .formatKit: return String(localized: "パーツ")
        case .textToSpeech: return String(localized: "AI読み上げ")
        case .mask, .overlayMask: return String(localized: "マスク")
        case .autoReframe: return String(localized: "オートリフレーム")
        case .stabilize: return String(localized: "スタビライザー")
        case .enhance: return String(localized: "画質補正")
        case .parallax, .overlayParallax: return String(localized: "3Dズーム")
        case .backgroundRemoval, .overlayBackgroundRemoval: return String(localized: "背景を消す")
        case .subjectFlash: return String(localized: "被写体フラッシュ")
        case .retouch: return String(localized: "レタッチ")
        case .clipKeyframes: return String(localized: "キーフレーム")
        case .textTracking, .overlayTracking: return String(localized: "トラッキング")
        case .mosaic: return String(localized: "モザイク")
        case .pacing: return String(localized: "中だるみ・編集チェック")
        case .autoEditTemplates: return String(localized: "おまかせテンプレ")
        case .dubbing: return String(localized: "吹き替え")
        case .soundEffects: return String(localized: "効果音")
        case .videoEffectAdd, .videoEffect: return String(localized: "映像エフェクト")
        }
    }

    /// パネルが編集する対象(タイトルに「速度 – クリップ2」のように出す)。全体設定のパネルは nil
    var targetSelection: EditorSelection? {
        switch self {
        case .speed(let id), .volume(let id), .filter(let id), .jlCut(let id), .colorAdjust(let id),
             .slip(let id), .transition(let id), .clipAnimation(let id), .geometry(let id), .speedCurve(let id),
             .audioEffects(let id), .beatDetect(let id), .hsl(let id), .lut(let id), .colorMatch(let id),
             .mask(let id), .autoReframe(let id), .stabilize(let id), .enhance(let id), .parallax(let id), .subjectFlash(let id),
             .retouch(let id):
            return .clip(id)
        case .backgroundRemoval(let id):
            return .clip(id)
        case .clipKeyframes(let id):
            return .clip(id)
        case .overlayBackgroundRemoval(let id):
            return .overlay(id)
        case .textEdit(let id):
            return .subtitle(id)
        case .overlayPlacement(let id), .overlayKenBurns(let id), .overlayVolume(let id),
             .overlaySpeed(let id), .overlayFilter(let id), .overlayKeyframes(let id), .overlayBlend(let id), .overlayTransition(let id), .overlayOpacity(let id),
             .overlayMask(let id), .overlayParallax(let id), .overlayTracking(let id):
            return .overlay(id)
        case .narrationVolume(let id), .narrationEffects(let id):
            return .narration(id)
        case .textStyle(let id), .textAnimation(let id), .textPlacement(let id), .textKeyframes(let id),
             .textTracking(let id), .mosaic(let id):
            return .text(id)
        case .drawingStyle(let id), .drawingTiming(let id):
            return .drawing(id)
        case .markerName(let id), .markerKind(let id):
            return .marker(id)
        case .bgmVolume:
            return .bgm
        case .videoEffect(let id):
            return .videoEffect(id)
        case .videoEffectAdd:
            return nil
        case .subtitleStyle, .captionTemplate, .aspect, .documentary, .titleCard, .lowerThird,
             .narrationRecord, .sticker, .colorScreen, .drawingCanvas, .watermark, .formatKit, .textToSpeech,
             .autoEditTemplates, .pacing, .dubbing, .soundEffects:
            return nil
        }
    }

    /// ✕「キャンセル」(開いたときの状態に戻す)を出すか。
    /// 選ぶとすぐ追加される・録音するなど、入口として使うパネルでは出さない
    var supportsCancel: Bool {
        switch self {
        case .sticker, .colorScreen, .narrationRecord, .textToSpeech, .autoEditTemplates, .formatKit, .pacing, .dubbing, .soundEffects:
            return false
        case .backgroundRemoval, .overlayBackgroundRemoval:
            return true
        case .clipKeyframes:
            return true
        case .videoEffectAdd:
            return false
        case .videoEffect:
            return true
        case .speed, .volume, .filter, .textEdit, .subtitleStyle, .aspect, .bgmVolume, .documentary,
             .titleCard, .lowerThird, .jlCut, .colorAdjust, .overlayPlacement, .overlayKenBurns,
             .overlayVolume, .overlaySpeed, .overlayFilter, .narrationVolume, .transition, .clipAnimation,
             .geometry, .speedCurve, .audioEffects, .beatDetect, .hsl, .lut, .colorMatch, .textStyle,
             .textAnimation, .textPlacement, .textKeyframes, .overlayKeyframes, .overlayBlend, .overlayTransition, .overlayOpacity,
             .narrationEffects, .drawingCanvas, .drawingStyle, .drawingTiming, .markerName, .markerKind,
             .captionTemplate, .watermark, .mask, .autoReframe, .stabilize, .enhance, .parallax, .subjectFlash, .retouch,
             .overlayMask, .overlayParallax, .textTracking, .overlayTracking, .mosaic, .slip:
            return true
        }
    }

    var height: CGFloat {
        switch self {
        case .filter, .overlayFilter: return 300
        case .documentary, .titleCard, .lowerThird: return 300
        case .colorAdjust, .overlayPlacement: return 320
        case .overlayKenBurns, .narrationRecord: return 280
        case .jlCut: return 250
        case .textStyle, .formatKit, .autoEditTemplates, .dubbing, .soundEffects: return 360
        case .mask, .overlayMask: return 340
        case .backgroundRemoval, .overlayBackgroundRemoval: return 360
        case .clipKeyframes: return 360
        case .videoEffectAdd, .videoEffect: return 340
        case .slip: return 350
        case .mosaic: return 300
        case .pacing: return 340
        case .overlayOpacity: return 170
        // キャプションのデザイン(テンプレート・色・サイズ・位置・フォントを 1 つにまとめた)
        case .subtitleStyle, .captionTemplate: return 360
        case .geometry, .speedCurve, .audioEffects, .hsl, .textPlacement, .textKeyframes,
             .overlayKeyframes, .watermark, .textToSpeech, .sticker,
             .autoReframe, .enhance, .subjectFlash, .retouch: return 320
        case .colorScreen: return 260
        case .transition, .overlayTransition, .clipAnimation, .beatDetect, .lut, .colorMatch, .textAnimation,
             .narrationEffects, .drawingStyle, .drawingCanvas,
             .stabilize, .parallax, .overlayParallax, .textTracking, .overlayTracking: return 280
        // 比率: 比率のタイル + 収め方の見本(高さ約 102)が切れずに見える高さ
        case .aspect: return 280
        // ボリューム(クリップ・ナレーション)はフェードイン・フェードアウトのスライダーぶん高い
        case .volume, .narrationVolume: return 330
        case .speed, .textEdit, .bgmVolume, .overlayVolume,
             .overlaySpeed, .overlayBlend, .drawingTiming, .markerName, .markerKind:
            return 220
        }
    }

    /// 選択状態が変わったときにこのパネルを開いたままにしてよいか
    func isCompatible(with selection: EditorSelection?) -> Bool {
        switch self {
        case .speed(let id), .volume(let id), .filter(let id), .jlCut(let id), .colorAdjust(let id),
             .slip(let id), .transition(let id), .clipAnimation(let id), .geometry(let id), .speedCurve(let id),
             .audioEffects(let id), .beatDetect(let id), .hsl(let id), .lut(let id), .colorMatch(let id),
             .mask(let id), .autoReframe(let id), .stabilize(let id), .enhance(let id), .parallax(let id), .subjectFlash(let id),
             .retouch(let id):
            return selection == .clip(id)
        case .backgroundRemoval(let id):
            return selection == .clip(id)
        case .clipKeyframes(let id):
            return selection == .clip(id)
        case .overlayBackgroundRemoval(let id):
            return selection == .overlay(id)
        case .textEdit(let id):
            return selection == .subtitle(id)
        case .subtitleStyle, .captionTemplate:
            return selection?.subtitleID != nil
        case .aspect:
            return true
        case .bgmVolume:
            return selection == .bgm
        case .overlayPlacement(let id), .overlayKenBurns(let id), .overlayVolume(let id),
             .overlaySpeed(let id), .overlayFilter(let id), .overlayKeyframes(let id), .overlayBlend(let id), .overlayTransition(let id), .overlayOpacity(let id),
             .overlayMask(let id), .overlayParallax(let id), .overlayTracking(let id):
            return selection == .overlay(id)
        case .narrationVolume(let id), .narrationEffects(let id):
            return selection == .narration(id)
        case .textStyle(let id), .textAnimation(let id), .textPlacement(let id), .textKeyframes(let id),
             .textTracking(let id), .mosaic(let id):
            return selection == .text(id)
        case .drawingStyle(let id), .drawingTiming(let id):
            return selection == .drawing(id)
        case .markerName(let id), .markerKind(let id):
            return selection == .marker(id)
        case .videoEffect(let id):
            return selection == .videoEffect(id)
        case .videoEffectAdd:
            return selection == nil
        case .pacing:
            return true
        case .formatKit:
            // ルートからも、クリップ選択中(選択範囲を保存)からも開ける
            return selection == nil || selection?.clipID != nil
        case .documentary, .titleCard, .lowerThird, .narrationRecord,
             .sticker, .colorScreen, .drawingCanvas, .watermark, .textToSpeech, .autoEditTemplates, .dubbing, .soundEffects:
            // ルート(何も選択していない)ツールバーから開くパネル
            return selection == nil
        }
    }
}

/// 時刻表示(m:ss)
enum EditorTimeFormat {
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// 0:05.2(停止中の表示。0.1 秒単位)
    static func tenths(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let scaled: Double = max(0, seconds) * 10
        let tenthsTotal: Int = Int(scaled.rounded(.down))
        let minutes: Int = tenthsTotal / 600
        let restTenths: Int = tenthsTotal % 600
        let secs: Int = restTenths / 10
        let fraction: Int = restTenths % 10
        return "\(minutes):" + String(format: "%02d", secs) + ".\(fraction)"
    }
}

// MARK: - 共通部品

/// パネルの外枠(✕「キャンセル」+タイトル+✓ボタン+中身)
struct EditorPanelContainer<Content: View>: View {
    let title: String
    let height: CGFloat
    /// nil 以外なら左上に ✕「キャンセル」(開いたときの状態に戻して閉じる)を出す
    var onCancel: (() -> Void)? = nil
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    /// キーボードが出ている間はヘッダーに「キーボードを閉じる」を出す(パネルの中の入力欄には閉じる手段がないため)
    @State private var isKeyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if let onCancel {
                    Button {
                        EditorHaptics.tap()
                        onCancel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                            Text("キャンセル")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("キャンセル")
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, onCancel == nil ? 10 : 0)
                Spacer(minLength: 4)
                if isKeyboardVisible {
                    Button {
                        EditorHaptics.tap()
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("キーボードを閉じる")
                }
                Button {
                    EditorHaptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完了")
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            // 中身が切れていることがわかるよう、スクロールバーを出し、開いたときに一度ちらっと見せる
            ScrollView(.vertical) {
                content()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(BrandStyle.surfaceStrong,
                    in: UnevenRoundedRectangle(topLeadingRadius: BrandStyle.Radius.sheet,
                                               topTrailingRadius: BrandStyle.Radius.sheet))
        .background(Color.black,
                    in: UnevenRoundedRectangle(topLeadingRadius: BrandStyle.Radius.sheet,
                                               topTrailingRadius: BrandStyle.Radius.sheet))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }
}

/// 選択肢チップ
struct EditorChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                // 選んでいるものは白く塗る(チップは小さいので枠だけだと見分けにくい)。角丸はアプリ共通
                .background(isSelected ? Color.white : BrandStyle.surfaceStrong,
                            in: RoundedRectangle(cornerRadius: BrandStyle.Radius.chip, style: .continuous))
                // 見た目はそのままで、押せる範囲だけ上下に広げる(高さ 44pt 相当)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .padding(.vertical, -7)
        }
        .buttonStyle(.plain)
    }
}

/// 対象が見つからないとき
struct EditorMissingPanelContent: View {
    var body: some View {
        Text("対象が見つかりません")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }
}

/// パネル内の小見出し(第3弾のパネル共通)
struct EditorSectionTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// ラベルつきのテキスト入力(第3弾のパネル共通)
struct EditorTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var multiline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorSectionTitle(title: title)
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// カプセル型の小さなボタン(第3弾のパネル共通)
struct EditorPillButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(prominent ? Color.accentColor : tint.opacity(0.15), in: Capsule())
                // 見た目はそのままで、押せる範囲だけ上下に広げる(高さ 44pt 相当)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .padding(.vertical, -5)
        }
        .buttonStyle(.plain)
    }
}

/// 名前と時間の 1 行(第3弾のパネル共通)
struct EditorItemHeaderRow: View {
    let systemImage: String
    let name: String
    let start: Double
    let end: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(MediaTimeText.precise(start)) – \(MediaTimeText.precise(end))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// ラベル+値表示つきのスライダー行
struct EditorSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(display)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}

// MARK: - 速度

struct EditorSpeedPanel: View {
    let project: EditorProject
    @Binding var clip: Clip

    private let presets: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]

    private func label(for value: Double) -> String {
        switch value {
        case 0.25: return "0.25x"
        case 0.5: return "0.5x"
        case 1.5: return "1.5x"
        default: return "\(Int(value))x"
        }
    }

    /// 速度を変えるとクリップの長さが変わるので、後ろの字幕・テキスト・オーバーレイなども同じ素材の位置に付いたまま動かす
    private func setSpeed(_ speed: Double) {
        let layout = project.captureClipLayout()
        clip.speed = min(max(speed, 0.25), 4)
        project.rippleTimelineItems(from: layout)
    }

    /// log2(速度) を -2 ... 2 で操作する(0.25x ... 4x)
    private var logSpeed: Binding<Double> {
        Binding<Double>(
            get: { log2(min(max(clip.speed, 0.25), 4)) },
            set: { newValue in
                let raw = pow(2.0, newValue)
                let rounded = (raw * 20).rounded() / 20
                setSpeed(rounded)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        EditorChip(title: label(for: preset),
                                   isSelected: abs(clip.speed - preset) < 0.001) {
                            setSpeed(preset)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("速度・デュレーション")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", clip.speed))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: logSpeed, in: -2...2)
                    .tint(.white)
                HStack {
                    Text("0.25x")
                    Spacer()
                    Text("1x")
                    Spacer()
                    Text("4x")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Text("長さ \(MediaTimeText.precise(clip.trimmedDuration)) → \(MediaTimeText.precise(clip.outputDuration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // 間のコマを作るなめらかスロー(FlowSlowControls.swift)
            EditorFlowSlowSection(project: project, clip: $clip)
        }
        .padding(.top, 6)
    }
}

// MARK: - 音量(クリップ)

struct EditorVolumePanel: View {
    @Bindable var project: EditorProject
    @Binding var clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $clip.isMuted) {
                Label("このクリップをミュート", systemImage: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline)
            }
            .tint(.accentColor)
            .disabled(!clip.hasAudio)

            if !clip.hasAudio {
                Text("このクリップには音声がありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // このクリップだけの音量(0〜200%)。全クリップの音量は「BGM・音量」のシートで変える
            EditorSliderRow(title: String(localized: "ボリューム"),
                            value: $clip.audio.volume,
                            range: 0...2,
                            display: "\(Int((clip.audio.volume * 100).rounded()))%")
                .disabled(!clip.hasAudio)
            HStack {
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.audio.volume = 1
                }
            }
            // 音のフェードイン・フェードアウト(0〜3 秒。AudioFadePanels.swift)
            AudioFadeSliders(fadeIn: $clip.audioFadeIn, fadeOut: $clip.audioFadeOut)
                .disabled(!clip.hasAudio)
        }
        .padding(.top, 6)
    }
}

// MARK: - フィルタ

struct EditorFilterPanel: View {
    let project: EditorProject
    @Binding var clip: Clip

    var body: some View {
        FilterPickerView(filter: $clip.filter,
                         sourceImage: clip.thumbnail,
                         onApplyToAll: {
                             // プリセット・強さ・明るさ・コントラスト・彩度だけを写す(各クリップの HSL・LUT・露出などは残す)
                             let look = clip.filter
                             for i in project.clips.indices {
                                 project.clips[i].filter = FilterPickerView.presetLook(from: look, onto: project.clips[i].filter)
                             }
                         })
    }
}

// MARK: - J カット / L カット(クリップ)

struct EditorJLCutPanel: View {
    @Binding var clip: Clip

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    /// 元素材の先頭より前の音は取れないため、J カットで実際に使える最大秒数
    private var availableLeadIn: Double { max(0, clip.startTime) }
    /// 元素材の末尾より後の音は取れないため、L カットで実際に使える最大秒数
    private var availableTailOut: Double { max(0, clip.duration - clip.endTime) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: String(localized: "Jカット"),
                                value: $clip.audio.audioLeadIn,
                                range: 0...3,
                                display: seconds(clip.audio.audioLeadIn))
                if clip.audio.audioLeadIn > availableLeadIn + 0.001 {
                    Text("※ 素材の先頭より前の音はないため、実際には最大 \(seconds(availableLeadIn)) になります")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: String(localized: "Lカット"),
                                value: $clip.audio.audioTailOut,
                                range: 0...3,
                                display: seconds(clip.audio.audioTailOut))
                if clip.audio.audioTailOut > availableTailOut + 0.001 {
                    Text("※ 素材の末尾より後の音はないため、実際には最大 \(seconds(availableTailOut)) になります")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if !clip.hasAudio {
                    Text("このクリップには音声がありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.audio.audioLeadIn = 0
                    clip.audio.audioTailOut = 0
                }
                .disabled(!clip.audio.hasSplitEdit)
                .opacity(clip.audio.hasSplitEdit ? 1 : 0.4)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 色調整(クリップ)

struct EditorColorAdjustPanel: View {
    @Binding var clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("カラープリセット: \(clip.filter.preset.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                EditorChip(title: String(localized: "リセット"), isSelected: false) {
                    clip.filter.adjustments = ColorAdjustments()
                }
                .disabled(clip.filter.adjustments.isIdentity)
                .opacity(clip.filter.adjustments.isIdentity ? 0.4 : 1)
            }

            EditorSliderRow(title: String(localized: "露出"),
                            value: $clip.filter.adjustments.exposure,
                            range: -2...2,
                            display: String(format: "%+.2f EV", clip.filter.adjustments.exposure))
            EditorSliderRow(title: String(localized: "明るさ"),
                            value: $clip.filter.adjustments.brightness,
                            range: -0.5...0.5,
                            display: String(format: "%+.2f", clip.filter.adjustments.brightness))
            EditorSliderRow(title: String(localized: "コントラスト"),
                            value: $clip.filter.adjustments.contrast,
                            range: 0.5...1.5,
                            display: String(format: "%.2f", clip.filter.adjustments.contrast))
            EditorSliderRow(title: String(localized: "彩度"),
                            value: $clip.filter.adjustments.saturation,
                            range: 0...2,
                            display: String(format: "%.2f", clip.filter.adjustments.saturation))
            EditorSliderRow(title: String(localized: "色温度"),
                            value: $clip.filter.adjustments.temperature,
                            range: -1...1,
                            display: String(format: "%+.2f", clip.filter.adjustments.temperature))
            EditorSliderRow(title: String(localized: "ハイライト"),
                            value: $clip.filter.adjustments.highlights,
                            range: -1...1,
                            display: String(format: "%+.2f", clip.filter.adjustments.highlights))
            EditorSliderRow(title: String(localized: "シャドウ"),
                            value: $clip.filter.adjustments.shadows,
                            range: -1...1,
                            display: String(format: "%+.2f", clip.filter.adjustments.shadows))
            EditorSliderRow(title: String(localized: "シャープネス"),
                            value: $clip.filter.adjustments.sharpness,
                            range: 0...1,
                            display: String(format: "%.2f", clip.filter.adjustments.sharpness))
        }
        .padding(.top, 6)
    }
}

// MARK: - テキスト編集(字幕 1 件)

struct EditorTextEditPanel: View {
    @Binding var cue: SubtitleCue

    private enum Field {
        case text
        case translation
    }

    /// 入力中の欄(見出しの右の「完了」でキーボードを閉じる)
    @FocusState private var focusedField: Field?

    private var translatedBinding: Binding<String> {
        Binding<String>(
            get: { cue.translatedText ?? "" },
            set: { newValue in
                cue.translatedText = newValue.isEmpty ? nil : newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(MediaTimeText.precise(cue.start)) – \(MediaTimeText.precise(cue.end))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                fieldHeader(String(localized: "テキスト"), field: .text)
                TextField("キャプションを入力", text: $cue.text, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .text)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldHeader(String(localized: "訳文(任意)"), field: .translation)
                TextField("Translation", text: translatedBinding, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focusedField, equals: .translation)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 6)
    }

    /// 欄の見出し。入力中は右に「完了」(キーボードを閉じる)を出す
    private func fieldHeader(_ title: String, field: Field) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if focusedField == field {
                Button {
                    focusedField = nil
                } label: {
                    Text("完了")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        // 見た目はそのままで、押せる範囲を 44pt に広げる
                        .padding(.vertical, 14)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .padding(.vertical, -14)
                        .padding(.horizontal, -8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - キャプションのデザイン(全キャプション共通)

/// テンプレート → 色 → サイズ → 位置 → フォントの順に 1 つのパネルにまとめる
/// (前は「スタイル」と「デザイン」の 2 つの入口に分かれていた)
struct EditorSubtitleStylePanel: View {
    @Bindable var project: EditorProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(String(localized: "テンプレート")) {
                CaptionTemplatePicker(selection: $project.subtitleStyle.template)
            }

            row(String(localized: "色")) {
                HStack(spacing: 14) {
                    ForEach(SubtitleColor.allCases) { color in
                        let isSelected = project.subtitleStyle.color == color
                        Button {
                            EditorHaptics.tap()
                            project.subtitleStyle.color = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                                // 選んでいる印はアプリ共通(白い 2pt の輪)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: 2)
                                        .padding(-4)
                                        .opacity(isSelected ? 1 : 0)
                                )
                                // 見た目はそのままで、押せる範囲を 44pt に広げる
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .padding(-8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.displayName)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            EditorColorRow(title: String(localized: "強調色"), color: EditorColorHex.binding($project.subtitleStyle.highlightColorHex))

            EditorSliderRow(title: String(localized: "文字サイズ"),
                            value: $project.subtitleStyle.sizeRatio,
                            range: 0.03...0.10,
                            display: "\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")

            Toggle("背景をつける", isOn: $project.subtitleStyle.hasBackground)
                .font(.subheadline)
                .tint(.accentColor)

            row(String(localized: "位置")) {
                CaptionPositionPicker(selection: $project.subtitleStyle.position)
            }

            row(String(localized: "表示")) {
                CaptionDisplayModePicker(selection: $project.subtitleStyle.displayMode)
            }

            EditorFontPickerRow(title: String(localized: "フォント"), fontName: $project.subtitleStyle.fontName)
        }
        .padding(.top, 6)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - 比率

struct EditorAspectPanel: View {
    @Bindable var project: EditorProject

    /// 使いみちの名前
    static func useName(_ aspect: CanvasAspect) -> String {
        switch aspect {
        case .original: return String(localized: "元のまま")
        case .portrait9x16: return String(localized: "TikTok・リール・ショート")
        case .landscape16x9: return "YouTube"
        case .square: return String(localized: "正方形")
        case .portrait4x5: return String(localized: "投稿")
        }
    }

    static func useIcon(_ aspect: CanvasAspect) -> String? {
        switch aspect {
        case .original: return "film"
        case .portrait9x16: return "iphone"
        case .landscape16x9: return "play.rectangle.fill"
        case .square: return nil
        case .portrait4x5: return "photo"
        }
    }

    private func ratioText(_ aspect: CanvasAspect) -> String? {
        switch aspect {
        case .original: return nil
        case .portrait9x16: return "9:16"
        case .landscape16x9: return "16:9"
        case .square: return "1:1"
        case .portrait4x5: return "4:5"
        }
    }

    static func scalingName(_ mode: ScalingMode) -> String {
        switch mode {
        case .fit: return String(localized: "黒帯")
        case .fitBlur: return String(localized: "ぼかし")
        case .fill: return String(localized: "拡大")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(CanvasAspect.allCases) { aspect in
                        aspectTile(aspect)
                    }
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                EditorSectionTitle(title: String(localized: "収め方"))
                HStack(spacing: 6) {
                    ForEach(ScalingMode.allCases) { mode in
                        EditorVisualTile(title: Self.scalingName(mode), isSelected: project.canvas.scaling == mode) {
                            project.canvas.scaling = mode
                        } preview: {
                            ScalingModePreview(mode: mode)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .disabled(project.canvas.aspect == .original)
                .opacity(project.canvas.aspect == .original ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
    }

    /// 縦横比どおりの小さな枠 + 使いみちの名前
    private func aspectTile(_ aspect: CanvasAspect) -> some View {
        let selected = project.canvas.aspect == aspect
        let ratio = aspect.ratio ?? (16.0 / 9.0)
        let boxHeight: CGFloat = 40
        let boxWidth: CGFloat = min(56, boxHeight * ratio)
        let height: CGFloat = boxWidth / ratio
        return Button {
            EditorHaptics.tap()
            project.canvas.aspect = aspect
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(style: aspect == .original
                                      ? StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                                      : StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.06)))
                        .frame(width: boxWidth, height: height)
                    VStack(spacing: 1) {
                        if let icon = Self.useIcon(aspect) {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        if let ratioText = ratioText(aspect) {
                            Text(ratioText)
                                .font(.system(size: 8, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
                }
                .frame(height: 44)
                Text(Self.useName(aspect))
                    .font(.system(size: 11, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 64, minHeight: 80)
            .background(selected ? BrandStyle.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: BrandStyle.Radius.card, style: .continuous))
            .brandSelected(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.useName(aspect))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 収め方の見本(縦の画面に横の映像を入れたとき)
private struct ScalingModePreview: View {
    let mode: ScalingMode

    private let content = LinearGradient(colors: [Color(red: 0.86, green: 0.47, blue: 0.13), Color(red: 0.76, green: 0.19, blue: 0.33)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 横長(16:9)の映像。EditorVisualTile の縦長の枠(42x70)の幅に合わせる
    private var strip: some View {
        Rectangle().fill(content).aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    var body: some View {
        ZStack {
            switch mode {
            case .fit:
                Color.black
                strip
            case .fitBlur:
                Rectangle().fill(content).scaleEffect(1.6).blur(radius: 6).opacity(0.7)
                strip
            case .fill:
                Rectangle().fill(content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - BGM 音量

struct EditorBGMVolumePanel: View {
    @Bindable var project: EditorProject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(project.audio.bgmName ?? "BGM", systemImage: "music.note")
                .font(.subheadline)
                .lineLimit(1)

            EditorSliderRow(title: String(localized: "BGM の音量"),
                            value: $project.audio.bgmVolume,
                            range: 0...1,
                            display: "\(Int((project.audio.bgmVolume * 100).rounded()))%")

            Toggle("最後の 2 秒でフェードアウト", isOn: $project.audio.bgmFadeOut)
                .font(.subheadline)
                .tint(.accentColor)
        }
        .padding(.top, 6)
    }
}
