import SwiftUI
import UIKit
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

    // ---- 第3弾: オーバーレイ ----
    case overlayKeyframes(UUID)
    case overlayBlend(UUID)

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

    // ---- 第4弾: オーバーレイ ----
    case overlayMask(UUID)
    case overlayParallax(UUID)

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

    var title: String {
        switch self {
        case .speed: return String(localized: "速度・デュレーション")
        case .volume: return String(localized: "ボリューム")
        case .filter: return String(localized: "カラープリセット")
        case .textEdit: return String(localized: "文字を直す")
        case .subtitleStyle: return String(localized: "キャプションのスタイル")
        case .aspect: return String(localized: "比率")
        case .bgmVolume: return String(localized: "BGM の音量")
        case .documentary: return String(localized: "全体の仕上げ")
        case .titleCard: return String(localized: "章タイトル")
        case .lowerThird: return String(localized: "名前テロップ")
        case .jlCut: return String(localized: "J/Lカット")
        case .colorAdjust: return String(localized: "カラー補正")
        case .overlayPlacement: return String(localized: "位置・サイズ")
        case .overlayKenBurns: return "Ken Burns"
        case .overlayVolume: return String(localized: "ボリューム")
        case .overlaySpeed: return String(localized: "速度・デュレーション")
        case .overlayFilter: return String(localized: "カラープリセット")
        case .narrationVolume: return String(localized: "ボリューム")
        case .narrationRecord: return String(localized: "ボイスオーバー録音")
        case .transition: return String(localized: "ビデオトランジション")
        case .clipAnimation: return String(localized: "アニメーション")
        case .geometry: return String(localized: "モーション・クロップ")
        case .speedCurve: return String(localized: "タイムリマップ")
        case .audioEffects: return String(localized: "オーディオエフェクト")
        case .beatDetect: return String(localized: "ビートに合わせる")
        case .hsl: return String(localized: "HSL セカンダリ")
        case .lut: return String(localized: "LUT を参照")
        case .colorMatch: return String(localized: "カラーマッチ")
        case .textStyle: return String(localized: "文字・スタイル")
        case .textAnimation: return String(localized: "アニメーション")
        case .textPlacement: return String(localized: "位置・サイズ")
        case .textKeyframes: return String(localized: "キーフレーム")
        case .sticker: return String(localized: "ステッカー")
        case .overlayKeyframes: return String(localized: "キーフレーム")
        case .overlayBlend: return String(localized: "描画モード")
        case .narrationEffects: return String(localized: "オーディオエフェクト")
        case .drawingCanvas: return String(localized: "手書き")
        case .drawingStyle: return String(localized: "色・太さ")
        case .drawingTiming: return String(localized: "表示する時間")
        case .markerName: return String(localized: "マーカーの名前")
        case .markerKind: return String(localized: "色・種類")
        case .captionTemplate: return String(localized: "キャプションのデザイン")
        case .watermark: return String(localized: "ロゴ・透かし")
        case .formatKit: return String(localized: "フォーマット")
        case .textToSpeech: return String(localized: "AI読み上げ")
        case .mask, .overlayMask: return String(localized: "マスク")
        case .autoReframe: return String(localized: "オートリフレーム")
        case .stabilize: return String(localized: "スタビライザー")
        case .enhance: return String(localized: "画質補正")
        case .parallax, .overlayParallax: return String(localized: "3Dズーム")
        case .textTracking, .overlayTracking: return String(localized: "トラッキング")
        case .mosaic: return String(localized: "モザイク")
        case .pacing: return String(localized: "中だるみ・編集チェック")
        case .autoEditTemplates: return String(localized: "おまかせテンプレ")
        }
    }

    /// パネルが編集する対象(タイトルに「速度 – クリップ2」のように出す)。全体設定のパネルは nil
    var targetSelection: EditorSelection? {
        switch self {
        case .speed(let id), .volume(let id), .filter(let id), .jlCut(let id), .colorAdjust(let id),
             .transition(let id), .clipAnimation(let id), .geometry(let id), .speedCurve(let id),
             .audioEffects(let id), .beatDetect(let id), .hsl(let id), .lut(let id), .colorMatch(let id),
             .mask(let id), .autoReframe(let id), .stabilize(let id), .enhance(let id), .parallax(let id):
            return .clip(id)
        case .textEdit(let id):
            return .subtitle(id)
        case .overlayPlacement(let id), .overlayKenBurns(let id), .overlayVolume(let id),
             .overlaySpeed(let id), .overlayFilter(let id), .overlayKeyframes(let id), .overlayBlend(let id),
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
        case .subtitleStyle, .captionTemplate, .aspect, .documentary, .titleCard, .lowerThird,
             .narrationRecord, .sticker, .drawingCanvas, .watermark, .formatKit, .textToSpeech,
             .autoEditTemplates, .pacing:
            return nil
        }
    }

    /// ✕「やめる」(開いたときの状態に戻す)を出すか。
    /// 選ぶとすぐ追加される・録音するなど、入口として使うパネルでは出さない
    var supportsCancel: Bool {
        switch self {
        case .sticker, .narrationRecord, .textToSpeech, .autoEditTemplates, .formatKit, .pacing:
            return false
        case .speed, .volume, .filter, .textEdit, .subtitleStyle, .aspect, .bgmVolume, .documentary,
             .titleCard, .lowerThird, .jlCut, .colorAdjust, .overlayPlacement, .overlayKenBurns,
             .overlayVolume, .overlaySpeed, .overlayFilter, .narrationVolume, .transition, .clipAnimation,
             .geometry, .speedCurve, .audioEffects, .beatDetect, .hsl, .lut, .colorMatch, .textStyle,
             .textAnimation, .textPlacement, .textKeyframes, .overlayKeyframes, .overlayBlend,
             .narrationEffects, .drawingCanvas, .drawingStyle, .drawingTiming, .markerName, .markerKind,
             .captionTemplate, .watermark, .mask, .autoReframe, .stabilize, .enhance, .parallax,
             .overlayMask, .overlayParallax, .textTracking, .overlayTracking, .mosaic:
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
        case .textStyle, .formatKit, .autoEditTemplates: return 360
        case .mask, .overlayMask: return 340
        case .mosaic: return 300
        case .pacing: return 340
        case .geometry, .speedCurve, .audioEffects, .hsl, .textPlacement, .textKeyframes,
             .overlayKeyframes, .watermark, .textToSpeech, .sticker, .captionTemplate,
             .autoReframe, .enhance: return 320
        case .transition, .clipAnimation, .beatDetect, .lut, .colorMatch, .textAnimation,
             .narrationEffects, .drawingStyle, .drawingCanvas,
             .stabilize, .parallax, .overlayParallax, .textTracking, .overlayTracking: return 280
        case .speed, .volume, .textEdit, .subtitleStyle, .aspect, .bgmVolume, .overlayVolume,
             .overlaySpeed, .narrationVolume, .overlayBlend, .drawingTiming, .markerName, .markerKind:
            return 220
        }
    }

    /// 選択状態が変わったときにこのパネルを開いたままにしてよいか
    func isCompatible(with selection: EditorSelection?) -> Bool {
        switch self {
        case .speed(let id), .volume(let id), .filter(let id), .jlCut(let id), .colorAdjust(let id),
             .transition(let id), .clipAnimation(let id), .geometry(let id), .speedCurve(let id),
             .audioEffects(let id), .beatDetect(let id), .hsl(let id), .lut(let id), .colorMatch(let id),
             .mask(let id), .autoReframe(let id), .stabilize(let id), .enhance(let id), .parallax(let id):
            return selection == .clip(id)
        case .textEdit(let id):
            return selection == .subtitle(id)
        case .subtitleStyle, .captionTemplate:
            return selection?.subtitleID != nil
        case .aspect:
            return true
        case .bgmVolume:
            return selection == .bgm
        case .overlayPlacement(let id), .overlayKenBurns(let id), .overlayVolume(let id),
             .overlaySpeed(let id), .overlayFilter(let id), .overlayKeyframes(let id), .overlayBlend(let id),
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
        case .pacing:
            return true
        case .formatKit:
            // ルートからも、クリップ選択中(選択範囲を保存)からも開ける
            return selection == nil || selection?.clipID != nil
        case .documentary, .titleCard, .lowerThird, .narrationRecord,
             .sticker, .drawingCanvas, .watermark, .textToSpeech, .autoEditTemplates:
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

/// パネルの外枠(✕「やめる」+タイトル+✓ボタン+中身)
struct EditorPanelContainer<Content: View>: View {
    let title: String
    let height: CGFloat
    /// nil 以外なら左上に ✕「やめる」(開いたときの状態に戻して閉じる)を出す
    var onCancel: (() -> Void)? = nil
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

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
                            Text("やめる")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("やめる")
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, onCancel == nil ? 10 : 0)
                Spacer(minLength: 4)
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

            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color(white: 0.11),
                    in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
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
                .background(isSelected ? Color.white : Color.white.opacity(0.12), in: Capsule())
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

    /// log2(速度) を -2 ... 2 で操作する(0.25x ... 4x)
    private var logSpeed: Binding<Double> {
        Binding<Double>(
            get: { log2(min(max(clip.speed, 0.25), 4)) },
            set: { newValue in
                let raw = pow(2.0, newValue)
                let rounded = (raw * 20).rounded() / 20
                clip.speed = min(max(rounded, 0.25), 4)
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
                            clip.speed = preset
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

            EditorSliderRow(title: String(localized: "元の音声の音量(全クリップ共通)"),
                            value: $project.audio.originalVolume,
                            range: 0...1,
                            display: "\(Int((project.audio.originalVolume * 100).rounded()))%")
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
                             project.applyFilterToAllClips(clip.filter)
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
            Text("Jカットは音声を映像より先に出し、Lカットは映像が切り替わった後も音声を残すつなぎ方です。会話や街の音が自然につながります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                EditorSliderRow(title: String(localized: "音を先に出す(J)"),
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
                EditorSliderRow(title: String(localized: "音を後に残す(L)"),
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
                Text("フィルタ: \(clip.filter.preset.displayName)")
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
            EditorSliderRow(title: String(localized: "色温度(− 青い / + 暖かい)"),
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
                Text("テキスト")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("字幕を入力", text: $cue.text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("訳文(任意)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Translation", text: translatedBinding, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - 字幕スタイル(全字幕共通)

struct EditorSubtitleStylePanel: View {
    @Bindable var project: EditorProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(String(localized: "位置")) {
                CaptionPositionPicker(selection: $project.subtitleStyle.position)
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
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                        .padding(-4)
                                )
                                // 見た目はそのままで、押せる範囲を 44pt に広げる
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .padding(-8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.displayName)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            EditorSliderRow(title: String(localized: "文字サイズ"),
                            value: $project.subtitleStyle.sizeRatio,
                            range: 0.03...0.10,
                            display: "\(Int((project.subtitleStyle.sizeRatio * 1000).rounded()))")

            Toggle("背景をつける", isOn: $project.subtitleStyle.hasBackground)
                .font(.subheadline)
                .tint(.accentColor)

            row(String(localized: "表示")) {
                CaptionDisplayModePicker(selection: $project.subtitleStyle.displayMode)
            }
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

    private func shortName(_ aspect: CanvasAspect) -> String {
        switch aspect {
        case .original: return String(localized: "元のまま")
        case .portrait9x16: return "9:16"
        case .landscape16x9: return "16:9"
        case .square: return "1:1"
        case .portrait4x5: return "4:5"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("画面比率")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CanvasAspect.allCases) { aspect in
                            EditorChip(title: shortName(aspect),
                                       isSelected: project.canvas.aspect == aspect) {
                                project.canvas.aspect = aspect
                            }
                        }
                    }
                }
                Text(project.canvas.aspect.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("はみ出し / 余白の扱い")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScalingMode.allCases) { mode in
                            EditorChip(title: mode.displayName,
                                       isSelected: project.canvas.scaling == mode) {
                                project.canvas.scaling = mode
                            }
                        }
                    }
                }
                .disabled(project.canvas.aspect == .original)
                .opacity(project.canvas.aspect == .original ? 0.4 : 1)
            }
        }
        .padding(.top, 6)
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
