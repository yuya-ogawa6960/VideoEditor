import Foundation
import Observation
import UIKit
import AVFoundation

// =====================================================================
// フォーマット(オープニング・クロージング・ディバイダー)の保管庫。
// Documents/formats.json に保存。初回起動時に組み込みのひな形(starters)を入れる。
// ブロックの挿入は「背景色の静止画クリップ(生成した単色 PNG)」+ 章タイトル/テキストで行う。
// 単色 PNG は Caches に作る(black.png など。消えても作り直す。ProjectStore が復元時に解決する)。
// 呼び出しはメインスレッドから(EditorProject を触るため)。
// =====================================================================

/// パーツに保存した動画の素材の使い方。元のプロジェクトに同じ素材のクリップが無くても、
/// 保存したときと同じ範囲・速度・音量でクリップを組み立てられるようにする
struct FormatMediaInfo: Codable, Equatable {
    /// 素材全体の長さ(秒)
    var sourceDuration: Double
    var naturalSize: CGSize
    var preferredTransform: CGAffineTransform
    var hasAudio: Bool
    /// 使う範囲(素材の秒)
    var startTime: Double
    var endTime: Double
    var speed: Double = 1
    var volume: Float = 1
}

private struct StoredFormatBlock: Codable {
    var id: UUID
    var name: String
    var kind: String
    var duration: Double
    var backgroundColorHex: String?
    var titleCards: [StoredTitleCard]
    var textClips: [StoredTextClip]
    /// 素材のファイル名(mediaDirectory 内)または生成した単色 PNG の名前
    var mediaFile: String?
    var transitionOut: StoredTransition
    /// 動画の素材の使い方(古いファイルには無い)
    var mediaInfo: FormatMediaInfo?

    init(_ b: FormatBlock) {
        id = b.id
        name = b.name
        kind = b.kind.rawValue
        duration = b.duration
        backgroundColorHex = b.backgroundColorHex
        titleCards = b.titleCards.map { StoredTitleCard($0) }
        textClips = b.textClips.map { StoredTextClip($0) }
        mediaFile = b.mediaURL?.lastPathComponent
        transitionOut = StoredTransition(b.transitionOut)
        mediaInfo = b.mediaInfo
    }

    var value: FormatBlock {
        var b = FormatBlock(name: name, kind: FormatKind(rawValue: kind) ?? .opening)
        b.id = id
        b.duration = duration
        b.backgroundColorHex = backgroundColorHex
        b.titleCards = titleCards.map { $0.value }
        b.textClips = textClips.map { $0.value }
        // 素材が消えていれば背景色だけにする
        b.mediaURL = mediaFile.flatMap { ProjectStore.resolveStillImage($0) }
        if b.mediaURL == nil, b.backgroundColorHex == nil, mediaFile != nil {
            b.backgroundColorHex = "#000000"
        }
        b.transitionOut = transitionOut.value
        b.mediaInfo = b.mediaURL == nil ? nil : mediaInfo
        return b
    }
}

private struct FormatFile: Codable {
    var version = 1
    var blocks: [StoredFormatBlock]
}

@Observable
final class FormatKitStore {
    static let shared = FormatKitStore()

    /// 保存済みのブロック(表示順)
    private(set) var blocks: [FormatBlock] = []

    private let queue = DispatchQueue(label: "FormatKitStore.write", qos: .utility)

    static var fileURL: URL {
        let docs = StorageLocations.applicationSupport
        return docs.appendingPathComponent("formats.json")
    }

    private init() {
        reload()
    }

    // MARK: - 生成した単色の静止画(Caches)

    static let blackStillFileName = "black.png"
    /// 生成する静止画のピクセルサイズ
    static let generatedStillSize = CGSize(width: 1920, height: 1080)
    /// 静止画クリップの「素材の長さ」として使う十分大きい値(秒)
    static let stillSourceDuration: Double = 3600

    private static let stillLock = NSLock()

    static var generatedStillDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// 1920×1080 の黒い PNG(Caches/black.png)。なければ 1 回だけ作る
    static func blackStillURL() -> URL {
        makeSolidStill(fileName: blackStillFileName, color: .black)
    }

    /// 任意の色の 1920×1080 PNG(Caches/solid_RRGGBB.png)。黒は black.png
    static func solidStillURL(colorHex: String) -> URL {
        guard let color = UIColor(hex: colorHex) else { return blackStillURL() }
        let hex = color.hexString
        if hex == "#000000" { return blackStillURL() }
        return makeSolidStill(fileName: "solid_\(hex.dropFirst()).png", color: color)
    }

    /// 任意の色・大きさの PNG(Caches/solid_RRGGBB_幅x高さ.png)。パーツの背景は作品の大きさで作る
    /// (1920×1080 だけだと、比率が「元のまま」の作品の先頭に入れたとき、作品全体が 16:9 の横長になっていた)
    static func solidStillURL(colorHex: String, size: CGSize) -> URL {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width >= 16, height >= 16, width <= 8192, height <= 8192,
              !(width == Int(generatedStillSize.width) && height == Int(generatedStillSize.height)) else {
            return solidStillURL(colorHex: colorHex)
        }
        let color = UIColor(hex: colorHex) ?? .black
        let hex = color.hexString
        return makeSolidStill(fileName: "solid_\(hex.dropFirst())_\(width)x\(height).png", color: color,
                              size: CGSize(width: width, height: height))
    }

    /// 生成した単色 PNG の名前なら(消えていれば作り直して)URL を返す。それ以外の名前は nil
    static func generatedStillURL(fileName: String) -> URL? {
        if fileName == blackStillFileName { return blackStillURL() }
        guard fileName.hasPrefix("solid_"), fileName.hasSuffix(".png") else { return nil }
        let body = String(fileName.dropFirst(6).dropLast(4))
        // "RRGGBB"(1920×1080)または "RRGGBB_幅x高さ"
        let parts = body.split(separator: "_")
        guard parts.count == 1 || parts.count == 2, let hexPart = parts.first, hexPart.count == 6,
              let color = UIColor(hex: "#" + String(hexPart)) else { return nil }
        var size = generatedStillSize
        if parts.count == 2 {
            let dims = parts[1].split(separator: "x")
            guard dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]),
                  w >= 16, h >= 16, w <= 8192, h <= 8192 else { return nil }
            size = CGSize(width: w, height: h)
        }
        return makeSolidStill(fileName: fileName, color: color, size: size)
    }

    /// この URL が生成した単色 PNG か
    static func isGeneratedStill(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == blackStillFileName || (name.hasPrefix("solid_") && name.hasSuffix(".png"))
    }

    private static func makeSolidStill(fileName: String, color: UIColor,
                                       size: CGSize = FormatKitStore.generatedStillSize) -> URL {
        let url = generatedStillDirectory.appendingPathComponent(fileName)
        stillLock.lock()
        defer { stillLock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        if let data = image.pngData() {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("FormatKitStore: still write failed: \(error)")
            }
        }
        return url
    }

    // MARK: - 組み込みのひな形(ID は固定)

    private static func fixedID(_ s: String) -> UUID { UUID(uuidString: s) ?? UUID() }

    private static func centeredText(_ text: String, id: String, start: Double, duration: Double, sizeRatio: Double,
                                     fade: Double) -> TextClip {
        var t = TextClip(text: text, start: start)
        t.id = fixedID(id)
        t.duration = duration
        t.center = .center
        t.widthRatio = 0.86
        var style = TextStyle()
        style.bold = true
        style.sizeRatio = sizeRatio
        style.colorHex = "#FFFFFF"
        style.alignment = .center
        t.style = style
        t.template = .plain
        t.animIn = .fade
        t.animInDuration = fade
        t.animOut = .fade
        t.animOutDuration = fade
        return t
    }

    /// 初回起動時に入れるひな形
    static let starters: [FormatBlock] = {
        var opening = FormatBlock(name: String(localized: "シンプルなオープニング"), kind: .opening)
        opening.id = FormatKitStore.fixedID("F0A7C2E0-0002-4000-8000-000000000001")
        opening.duration = 4
        opening.backgroundColorHex = "#000000"
        opening.titleCards = [
            TitleCard(id: FormatKitStore.fixedID("F0A7C2E0-0002-4000-8000-000000000011"), start: 0.4, duration: 3.2,
                      heading: String(localized: "第1章"), title: String(localized: "はじまり"), opaqueBackground: false)
        ]
        opening.transitionOut = ClipTransition(type: .fadeBlack, duration: 0.6)

        var closing = FormatBlock(name: String(localized: "クロージング"), kind: .closing)
        closing.id = FormatKitStore.fixedID("F0A7C2E0-0002-4000-8000-000000000002")
        closing.duration = 4
        closing.backgroundColorHex = "#000000"
        closing.textClips = [
            FormatKitStore.centeredText(String(localized: "ご視聴ありがとうございました"), id: "F0A7C2E0-0002-4000-8000-000000000021",
                                        start: 0.4, duration: 3.4, sizeRatio: 0.06, fade: 0.6)
        ]
        closing.transitionOut = ClipTransition(type: .fadeBlack, duration: 0.6)

        var divider = FormatBlock(name: String(localized: "ディバイダー"), kind: .divider)
        divider.id = FormatKitStore.fixedID("F0A7C2E0-0002-4000-8000-000000000003")
        divider.duration = 1.5
        divider.backgroundColorHex = "#000000"
        divider.textClips = [
            FormatKitStore.centeredText("・ ・ ・", id: "F0A7C2E0-0002-4000-8000-000000000031",
                                        start: 0, duration: 1.5, sizeRatio: 0.07, fade: 0.3)
        ]
        divider.transitionOut = ClipTransition(type: .fadeBlack, duration: 0.4)

        return [opening, closing, divider]
    }()

    /// 消したひな形を戻す(同じ ID のものが無ければ追加)
    func restoreStarters() {
        var changed = false
        for starter in Self.starters where !blocks.contains(where: { $0.id == starter.id }) {
            blocks.append(starter)
            changed = true
        }
        if changed { write() }
    }

    // MARK: - 追加 / 変更 / 削除

    func add(_ block: FormatBlock) {
        if let i = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[i] = block
        } else {
            blocks.append(block)
        }
        write()
        exportUsedRange(of: block)
    }

    /// パーツに保存した動画の使っている範囲を、別のファイル(Media フォルダ)に書き出してパーツの素材にする。
    /// 元の動画が写真ライブラリの一時ファイルなどで後から読めなくなっても、どのプロジェクトでも同じ映像が入るように。
    /// 書き出しが終わるまでと、書き出せなかったときは、元の動画の同じ範囲を使う(FormatMediaInfo)
    private func exportUsedRange(of block: FormatBlock) {
        // 長すぎる範囲(2 分超)は書き出さない(時間と容量がかかる。元の動画の範囲を使う)
        guard let source = block.mediaURL, let info = block.mediaInfo, !MediaStore.isImageFile(source),
              FileManager.default.fileExists(atPath: source.path), info.endTime > info.startTime + 0.05,
              info.endTime - info.startTime <= 120 else { return }
        let blockID = block.id
        Task { @MainActor [weak self] in
            let destination = MediaStore.uniqueDestination(forFileName: "part.mov")
            do {
                let asset = AVURLAsset(url: source)
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
                session.timeRange = CMTimeRange(start: CMTime(seconds: info.startTime, preferredTimescale: 600),
                                                end: CMTime(seconds: info.endTime, preferredTimescale: 600))
                try await session.export(to: destination, as: .mov)
                let exported = try await MediaStore.makeClip(from: destination)
                guard let self, var current = self.block(id: blockID), current.mediaURL == source else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                current.mediaURL = destination
                current.mediaInfo = FormatMediaInfo(sourceDuration: exported.duration, naturalSize: exported.naturalSize,
                                                    preferredTransform: exported.preferredTransform,
                                                    hasAudio: exported.hasAudio, startTime: 0, endTime: exported.duration,
                                                    speed: info.speed, volume: info.volume)
                self.update(current)
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    func update(_ block: FormatBlock) {
        guard let i = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[i] = block
        write()
    }

    func delete(id: UUID) {
        let before = blocks.count
        blocks.removeAll { $0.id == id }
        if blocks.count != before { write() }
    }

    func delete(_ block: FormatBlock) {
        delete(id: block.id)
    }

    func block(id: UUID) -> FormatBlock? {
        blocks.first { $0.id == id }
    }

    func blocks(of kind: FormatKind) -> [FormatBlock] {
        blocks.filter { $0.kind == kind }
    }

    // MARK: - プロジェクトから取り込む

    /// 出力タイムライン上の range にある章タイトルとテキストをコピーしてブロックを作る(時刻は range の先頭からの相対)。
    /// range が 1 つのクリップに収まっていれば、そのクリップの素材(静止画なら画像)を mediaURL にする。
    /// 返したブロックはまだ保存されていない(add を呼ぶ)
    func captureFromProject(_ project: EditorProject, range: ClosedRange<Double>, kind: FormatKind, name: String) -> FormatBlock {
        let lower = max(0, range.lowerBound)
        let upper = max(lower + 0.5, range.upperBound)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var block = FormatBlock(name: trimmedName.isEmpty ? kind.displayName : trimmedName, kind: kind)
        block.duration = upper - lower
        block.backgroundColorHex = "#000000"

        block.titleCards = project.titleCards.compactMap { (card: TitleCard) -> TitleCard? in
            let start = max(card.start, lower)
            let end = min(card.end, upper)
            guard end - start > 0.05 else { return nil }
            var copy = card
            copy.id = UUID()
            copy.start = start - lower
            copy.duration = end - start
            return copy
        }.sorted { $0.start < $1.start }

        block.textClips = project.textClips.compactMap { (text: TextClip) -> TextClip? in
            let start = max(text.start, lower)
            let end = min(text.end, upper)
            guard end - start > 0.05 else { return nil }
            var copy = text
            copy.id = UUID()
            copy.start = start - lower
            copy.duration = end - start
            copy.keyframes = copy.keyframes.map { k in
                var kk = k
                kk.id = UUID()
                return kk
            }
            return copy
        }.sorted { $0.start < $1.start }

        // 1 つのクリップに収まっていれば、その素材を使う
        let starts = project.clipStartTimes()
        for (i, clip) in project.clips.enumerated() where i < starts.count {
            let clipStart = starts[i]
            let clipEnd = clipStart + clip.outputDuration
            if lower >= clipStart - 0.01, upper <= clipEnd + 0.01 {
                let media = clip.stillImageURL ?? clip.url
                if Self.isGeneratedStill(media) {
                    block.mediaURL = nil
                    block.backgroundColorHex = "#000000"
                } else {
                    block.mediaURL = media
                    // 動画は使っている範囲・速度・音量も残す(前は素材の URL だけだったので、挿入すると元の動画の先頭が入り、
                    // 別のプロジェクトでは同じ素材のクリップが無くて黒い画面になっていた)。逆再生のクリップは前の扱いのまま
                    if !clip.isStill, !(clip.isReversed && clip.reversedURL != nil) {
                        let lowerSource = clip.sourceTime(atOutputOffset: max(0, lower - clipStart))
                        let upperSource = clip.sourceTime(atOutputOffset: min(clip.outputDuration, upper - clipStart))
                        if upperSource > lowerSource + 0.05 {
                            let speed = (upperSource - lowerSource) / max(0.1, min(upper, clipEnd) - max(lower, clipStart))
                            block.mediaInfo = FormatMediaInfo(sourceDuration: clip.duration, naturalSize: clip.naturalSize,
                                                              preferredTransform: clip.preferredTransform,
                                                              hasAudio: clip.hasAudio, startTime: lowerSource,
                                                              endTime: upperSource, speed: min(max(speed, 0.25), 4),
                                                              volume: clip.audio.volume)
                        }
                    }
                }
                break
            }
        }
        return block
    }

    // MARK: - プロジェクトへ挿入する

    /// ブロックをタイムライン上の timelineTime に挿入する。
    /// - 背景色または素材があるブロック: その位置(クリップの途中なら分割してから)に block.duration の
    ///   静止画クリップ(生成した単色 PNG、または画像素材)を入れ、それ以降の字幕・テキスト・オーバーレイなどを
    ///   実際に伸びた長さ(トランジションの重なりを引いた長さ)だけ後ろへずらす。挿入したクリップのトランジションは block.transitionOut、
    ///   直前のクリップにトランジションが無ければ同じものを付ける。
    /// - 背景色も素材も無いブロック: クリップは入れず、章タイトルとテキストだけを timelineTime から重ねる。
    /// 元に戻す用の記録(EditorHistory.record)は呼び出し側で行う
    func insert(_ block: FormatBlock, into project: EditorProject, at timelineTime: Double) {
        let insertsClip = block.mediaURL != nil || block.backgroundColorHex != nil
        let requested = timelineTime.isFinite ? max(0, timelineTime) : 0
        var insertTime: Double = min(requested, project.layoutDuration)

        if insertsClip {
            var index = Self.insertionIndex(in: project, at: requested)
            // 直前のクリップの途中なら分割する(端に近ければ近い方の境目に入れる)
            if index > 0 {
                let starts = project.clipStartTimes()
                let prev = project.clips[index - 1]
                let prevStart = starts[index - 1]
                let prevEnd = prevStart + prev.outputDuration
                if requested > prevStart + 0.01, requested < prevEnd - 0.01 {
                    var didSplit = false
                    if let location = project.locate(timelineTime: requested), location.index == index - 1 {
                        // 分割できれば: 前半 index-1、後半 index。その間に入れる
                        didSplit = project.splitClip(id: prev.id, atSourceTime: location.sourceTime)
                    }
                    if !didSplit, requested - prevStart < prevEnd - requested {
                        index -= 1
                    }
                }
            }
            let startsNow = project.clipStartTimes()
            // 差し込む前の、後ろのクリップの頭(末尾に足すときは nil)
            let rippleTime: Double? = index < startsNow.count ? startsNow[index] : nil
            let durationBefore = project.layoutDuration
            let clip = makeBlockClip(block, project: project)
            if index > 0, project.clips[index - 1].transition.type == .none {
                project.clips[index - 1].transition = block.transitionOut
            }
            project.clips.insert(clip, at: min(index, project.clips.count))
            // 後ろの部品は、実際に伸びた長さ(トランジションの重なりを引いた長さ)だけずらす
            // (前はパーツの長さだけずらしたので、後ろの字幕・ナレーションが重なりの分 0.4〜1.2 秒遅れていた)
            let grown = project.layoutDuration - durationBefore
            if let rippleTime {
                project.insertTimelineGap(at: rippleTime, length: grown)
            } else {
                project.extendChapterLabelsAfterAppend(previousDuration: durationBefore)
            }
            // 章タイトル・テキストは、入れたクリップの実際の開始(前のクリップとのトランジションの重なりを含む)から置く
            insertTime = project.outputRange(ofClip: clip.id)?.start ?? (rippleTime ?? durationBefore)
            // 同じ素材のクリップが無いプロジェクトに動画のパーツを入れたときは、サムネイルを後から読む
            if clip.thumbnail == nil, !clip.isStill {
                let clipID = clip.id
                let url = clip.url
                let at = clip.startTime + 0.05
                Task { @MainActor in
                    let image = await MediaStore.thumbnail(for: url, at: at, maxPixel: 320)
                    if let image, let i = project.index(of: clipID) {
                        project.clips[i].thumbnail = image
                    }
                }
            }
        }

        for card in block.titleCards {
            var copy = card
            copy.id = UUID()
            copy.start = insertTime + max(0, card.start)
            project.titleCards.append(copy)
        }
        for text in block.textClips {
            var copy = text
            copy.id = UUID()
            copy.start = insertTime + max(0, text.start)
            copy.keyframes = copy.keyframes.map { k in
                var kk = k
                kk.id = UUID()
                return kk
            }
            project.textClips.append(copy)
        }
        project.titleCards.sort { $0.start < $1.start }
        project.sortTextClips()
    }

    /// 出力タイムライン上の time 以降に始まるクリップの番号(無ければ末尾)
    private static func insertionIndex(in project: EditorProject, at time: Double) -> Int {
        let starts = project.clipStartTimes()
        if let i = starts.firstIndex(where: { $0 >= time - 0.01 }) { return i }
        return project.clips.count
    }

    /// time 以降に始まる部品(字幕・章タイトル・テロップ・オーバーレイ・ナレーション・テキスト・手書き・マーカー)を delta 秒ずらす
    private static func shiftItems(in project: EditorProject, from time: Double, by delta: Double) {
        guard delta > 0 else { return }
        // クリップはまだ入っていないので、いまの長さが差し込む前の長さ
        project.extendChapterLabels(forInsertionAt: time, length: delta, oldVideoEnd: project.layoutDuration)
        let threshold = time - 1e-6
        for i in project.subtitles.indices where project.subtitles[i].start >= threshold {
            project.subtitles[i].start += delta
            project.subtitles[i].end += delta
            for j in project.subtitles[i].words.indices {
                project.subtitles[i].words[j].start += delta
                project.subtitles[i].words[j].end += delta
            }
        }
        for i in project.titleCards.indices where project.titleCards[i].start >= threshold {
            project.titleCards[i].start += delta
        }
        for i in project.lowerThirds.indices where project.lowerThirds[i].start >= threshold {
            project.lowerThirds[i].start += delta
        }
        for i in project.overlays.indices where project.overlays[i].start >= threshold {
            project.overlays[i].start += delta
        }
        for i in project.narration.indices where project.narration[i].start >= threshold {
            project.narration[i].start += delta
        }
        for i in project.textClips.indices
        where project.textClips[i].start >= threshold || project.chapterLabelFollowsMarker(project.textClips[i], threshold: threshold) {
            project.textClips[i].start += delta
        }
        for i in project.drawings.indices where project.drawings[i].start >= threshold {
            project.drawings[i].start += delta
        }
        for i in project.videoEffects.indices where project.videoEffects[i].start >= threshold {
            project.videoEffects[i].start += delta
        }
        for i in project.markers.indices where project.markers[i].time >= threshold {
            project.markers[i].time += delta
        }
    }

    /// ブロックのクリップを作る。素材が動画なら、保存したときの素材の情報(FormatMediaInfo)から作る。
    /// 古いパーツはプロジェクト内の同じ素材から情報を借りる(無ければ背景色の静止画)
    private func makeBlockClip(_ block: FormatBlock, project: EditorProject) -> Clip {
        let duration = max(0.5, block.duration)
        let fm = FileManager.default

        if let media = block.mediaURL, !MediaStore.isImageFile(media), fm.fileExists(atPath: media.path) {
            let source = project.clips.first(where: { $0.url == media && !$0.isStill })
            if let info = block.mediaInfo, info.sourceDuration > 0.1 {
                // 保存したときの範囲・速度・音量で作る(同じ素材のクリップがプロジェクトに無くてもよい)
                var clip = Clip(url: media, duration: info.sourceDuration, naturalSize: info.naturalSize,
                                preferredTransform: info.preferredTransform, hasAudio: info.hasAudio,
                                thumbnail: source?.thumbnail, name: block.name)
                clip.startTime = min(max(0, info.startTime), info.sourceDuration - 0.1)
                clip.endTime = min(info.sourceDuration, max(clip.startTime + 0.1, info.endTime))
                clip.speed = min(max(info.speed, 0.25), 4)
                clip.audio.volume = info.volume
                clip.transition = block.transitionOut
                return clip
            }
            if let source {
                var clip = Clip(url: media, duration: source.duration, naturalSize: source.naturalSize,
                                preferredTransform: source.preferredTransform, hasAudio: source.hasAudio,
                                thumbnail: source.thumbnail, name: block.name)
                clip.startTime = 0
                clip.endTime = min(source.duration, duration)
                clip.transition = block.transitionOut
                return clip
            }
        }

        var imageURL: URL? = nil
        if let media = block.mediaURL, MediaStore.isImageFile(media), fm.fileExists(atPath: media.path) {
            imageURL = media
        }
        // 単色の背景は作品の大きさで作る(比率が「元のまま」の作品の先頭に入れても、作品の比率が変わらないように)
        let url = imageURL ?? Self.solidStillURL(colorHex: block.backgroundColorHex ?? "#000000",
                                                 size: CompositionBuilder.renderSize(for: project.snapshot(), purpose: .export))
        let size = MediaStore.imagePixelSize(of: url) ?? Self.generatedStillSize
        let thumbnail = MediaStore.makeImageClipThumbnail(url: url, maxPixel: 320)
        var clip = Clip(url: url, duration: Self.stillSourceDuration, naturalSize: size,
                        preferredTransform: .identity, hasAudio: false,
                        thumbnail: thumbnail, name: block.name)
        clip.stillImageURL = url
        clip.startTime = 0
        clip.endTime = duration
        clip.isMuted = true
        clip.transition = block.transitionOut
        return clip
    }

    // MARK: - 読み込み / 書き込み

    func reload() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 初回: ひな形を入れて保存する
            blocks = Self.starters
            write()
            return
        }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FormatFile.self, from: data) else {
            blocks = Self.starters
            return
        }
        blocks = file.blocks.map { $0.value }
    }

    private func write() {
        let file = FormatFile(blocks: blocks.map { StoredFormatBlock($0) })
        let url = Self.fileURL
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
            } catch {
                print("FormatKitStore: write failed: \(error)")
            }
        }
    }
}
