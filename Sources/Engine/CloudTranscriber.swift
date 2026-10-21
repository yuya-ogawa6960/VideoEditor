import Foundation
import AVFoundation
import NaturalLanguage
import UIKit

// =====================================================================
// クラウド音声認識(OpenAI Audio Transcriptions API)
//
// - 音声は 16kHz モノラル AAC(m4a、約 32kbps)にして約 2 分(maxPieceSeconds)/ ≤20MB ごとに分け、
//   最大 maxConcurrentPieces 本を同時に送る(1 本終わるたびに次を投入)。結果はピース順に連結する
// - 方式(AppSettings.cloudQuality):
//   - 速度優先: fastModel(whisper-1、verbose_json + 単語時刻)
//   - 精度優先: primaryModel(gpt-4o-transcribe 系、セグメント時刻付き JSON)を試し、
//     4xx の「モデル/パラメータ非対応」エラーなら fallbackModel(whisper-1、単語時刻付き)へ切り替える。
//     切り替えは同じ実行の中で記憶し、以降に送るピースは最初からフォールバックを使う
// - 単語時刻があればそれを、無ければセグメント内で文字数比に均等配分、
//   それも無ければ本文全体をピースの長さに均等配分する
// - whisper-1 が無音区間と判定したセグメント(no_speech_prob 高・avg_logprob 低)は捨てる(無音での幻聴対策)
// - 一時的な通信エラー(タイムアウト・回線切れ・NSPOSIXErrorDomain の接続中断など)はそのピースだけを送り直す(他のピースは止めない):
//   - 送信中にバックグラウンド(画面ロックなど)へ入っていたなら(戻ってから失敗が届いた場合も含む)、
//     フォアグラウンドに戻るまで待ってから送り直す(回数に数えない)。
//     バックグラウンド中は新しいピースの送信も始めない(送信中のものは beginBackgroundTask の猶予で終わらせる)
//   - フォアグラウンドなら 2・4・8・16 秒おいて送り直し、1 ピースで合計 6 回失敗したら諦める
// - 音声の切り出しがバックグラウンドへ入った間に失敗したときも、戻ってから切り出し直す(数回まで)
// - 継続処理(BGContinuedProcessingTask)が動いている間は、BackgroundPauseReporter.allowsBackgroundWork が true になり、
//   バックグラウンドでもフォアグラウンド待ちをしない(一時的な通信エラーはフォアグラウンドと同じく回数に数えて送り直す)
// - TranscriptionService のクラウド経路は transcribeClips を使う: 全クリップの全ピースを先に切り出してから
//   1 つのジョブにまとめ、CloudBackgroundUploader(背景 URLSession)に預ける。ロック中・アプリが止められた後も
//   送信が続き、結果は従来と同じ解析・オフセット・範囲の丸めでトークンにする。
//   背景セッションを使えないとき(継続処理中にバックグラウンドで送り始めるとき・登録に失敗したとき)は、
//   切り出したピースをこのプロセスから従来どおり送る。背景セッションに預けた後も、継続処理中にバックグラウンドで
//   必要になった送り直しは CloudBackgroundUploader がこのプロセスから送る。作業フォルダも作れなければ
//   CloudBackgroundUploaderError.unavailable を投げる(呼び出し側はクリップごとの従来の経路 transcribe へ)
// - API キーはログに出さない(ジョブの記録にも保存しない)
// =====================================================================

enum CloudTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(String)
    case offline
    case timedOut
    case network(String)
    case fileTooLarge
    case server(status: Int, message: String)
    case badResponse
    case noAudio

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "OpenAI の API キーが設定されていません。「文字起こしの方式」の画面でキーを入力してください。")
        case .invalidAPIKey:
            if CloudAIGateway.usesPoints || AccountService.shared.source == .points {
                return String(localized: "ログインの期限が切れました。「文字起こしの方式」の画面で、もう一度 Apple でサインインしてください。")
            }
            return String(localized: "APIキーが正しくありません。「文字起こしの方式」の画面で OpenAI の API キーを確認してください。")
        case .rateLimited(let detail):
            return detail.isEmpty ? String(localized: "利用上限です。しばらく待ってからもう一度お試しください。")
                                  : String(localized: "利用上限です。\(detail)")
        case .offline:
            return String(localized: "インターネットに接続されていません。通信環境を確認してください。")
        case .timedOut:
            return String(localized: "サーバーの応答がタイムアウトしました。通信環境を確認してもう一度お試しください。")
        case .network(let detail):
            return String(localized: "通信エラー: \(detail)")
        case .fileTooLarge:
            return String(localized: "音声ファイルが大きすぎて送信できません。")
        case .server(let status, let message):
            return String(localized: "OpenAI サーバーがエラーを返しました(\(status)): \(message)")
        case .badResponse:
            return String(localized: "サーバーの応答を読み取れませんでした。")
        case .noAudio:
            return String(localized: "送信できる音声がありません。")
        }
    }
}

final class CloudTranscriber: @unchecked Sendable {
    static let shared = CloudTranscriber()

    /// 送り先(ポイントを使う設定なら Video Mania のサーバー。CloudAIGateway)
    static var endpoint: URL { CloudAIGateway.transcriptionsURL }

    /// 精度優先で最初に試すモデル。gpt-4o-transcribe 系で時刻付き(diarized_json)を返せるもの
    static var primaryModel = "gpt-4o-transcribe-diarize"
    /// 速度優先で使うモデル(verbose_json + 単語/セグメント時刻)
    static var fastModel = "whisper-1"
    /// primary が 4xx(モデル/パラメータ非対応)のときに使うモデル(verbose_json + 単語時刻)
    static var fallbackModel = "whisper-1"

    /// 1 ピースの長さ(秒)。短く分けて同時に送るほど全体の待ち時間が短くなる
    static let maxPieceSeconds: Double = 120
    /// 同時に送るピース数の上限
    static let maxConcurrentPieces = 4
    /// 1 ピースの最大サイズ(バイト)
    static let maxPieceBytes: Int64 = 20 * 1024 * 1024
    /// 1 リクエストの待ち時間の上限(秒)。ピースは約 2 分の音声。whisper-1 は速いので短め、精度優先モデルは長め
    static let whisperRequestTimeout: TimeInterval = 120
    static let accurateRequestTimeout: TimeInterval = 240
    /// バックグラウンドへ入った間に失敗した切り出しをやり直す回数の上限(1 ピースあたり。最初の 1 回を含む)
    static let maxExtractionAttempts = 3

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        // セッション側は長い方(精度優先)に合わせ、モデルごとの値はリクエスト側(send)で決める。
        // どちらが優先されても whisper-1 は 120 秒、精度優先モデルは 240 秒になる
        configuration.timeoutIntervalForRequest = Self.accurateRequestTimeout
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    /// 方式ごとに最初に使うモデル
    static func model(for quality: CloudTranscriptionQuality) -> String {
        switch quality {
        case .fast: return fastModel
        case .accurate: return primaryModel
        }
    }

    // MARK: - 公開 API

    /// 音声ファイル全体を認識し、ファイル先頭からの秒のトークン列を返す。language は "ja" / "en"
    func transcribe(audioURL: URL, language: String, apiKey: String? = nil,
                    progress: @escaping (Double) -> Void) async throws -> [TimedToken] {
        try await transcribe(sourceURL: audioURL, start: 0, end: nil, language: language,
                             apiKey: apiKey, progress: progress)
    }

    /// 元素材 sourceURL の start〜end(秒。end が nil なら末尾まで)を認識し、元素材上の秒のトークン列を返す。
    /// - quality: nil なら AppSettings.shared.cloudQuality
    /// - pauseReporter: バックグラウンド待ち(一時停止)の開始・終了の通知先(任意)
    /// - progress: 完了ピース数 / 全ピース数(0〜1)
    /// - pieceProgress: (完了ピース数, 全ピース数)
    /// progress / pieceProgress はこの関数を呼んだタスクから順番に呼ばれる(メインスレッドではない)
    func transcribe(sourceURL: URL, start: Double, end: Double?, language: String, apiKey: String? = nil,
                    quality: CloudTranscriptionQuality? = nil,
                    pauseReporter: BackgroundPauseReporter? = nil,
                    progress: @escaping (Double) -> Void,
                    pieceProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil) async throws -> [TimedToken] {
        let key = (apiKey ?? AppSettings.shared.cloudCredential).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }
        // 送信・切り出しの途中でバックグラウンドへ入ったかを判定できるように、監視を始めておく
        await BackgroundEpoch.install()
        let resolvedQuality = quality ?? AppSettings.shared.cloudQuality
        let firstModel = Self.model(for: resolvedQuality)

        let asset = AVURLAsset(url: sourceURL)
        let assetDuration = try await asset.load(.duration).seconds
        let rangeStart = max(0, start)
        var rangeEnd = end ?? assetDuration
        if assetDuration.isFinite, assetDuration > 0 { rangeEnd = min(rangeEnd, assetDuration) }
        guard rangeEnd.isFinite, rangeEnd > rangeStart + 0.05 else { throw CloudTranscriptionError.noAudio }

        let ranges = Self.pieces(start: rangeStart, end: rangeEnd)
        guard !ranges.isEmpty else { throw CloudTranscriptionError.noAudio }
        let total = ranges.count
        let fallback = FallbackSwitch()
        let maxInFlight = max(1, Self.maxConcurrentPieces)
        progress(0)
        pieceProgress?(0, total)

        // 最大 maxInFlight 本を同時に処理し、1 本終わるたびに次を投入する。終わったピースの結果は collected に残る。
        // 一時的な通信エラーやバックグラウンド待ちは各ピースの中(transcribePiece)で再試行するので、ほかのピースは止めない。
        // 再試行を使い切ったなど、ピースが失敗を投げたとき(またはこのタスクがキャンセルされたとき)だけ残りはグループごとキャンセルされる
        let perPiece: [[TimedToken]] = try await withThrowingTaskGroup(of: PieceResult.self,
                                                                       returning: [[TimedToken]].self) { group in
            var collected = [[TimedToken]](repeating: [], count: total)
            var launched = 0
            var finished = 0
            while finished < total {
                try Task.checkCancellation()
                while launched < total, launched - finished < maxInFlight {
                    let index = launched
                    let range = ranges[index]
                    group.addTask {
                        let tokens = try await self.transcribeRange(range, sourceURL: sourceURL, language: language,
                                                                    apiKey: key, firstModel: firstModel,
                                                                    fallback: fallback, pauseReporter: pauseReporter,
                                                                    depth: 0)
                        return PieceResult(index: index, tokens: tokens)
                    }
                    launched += 1
                }
                guard let result = try await group.next() else { break }
                collected[result.index] = result.tokens
                finished += 1
                progress(min(1, Double(finished) / Double(total)))
                pieceProgress?(finished, total)
            }
            return collected
        }
        try Task.checkCancellation()

        // ピース順に連結(各ピースのトークンはそのピースの範囲内に収めてある)。同じ時刻なら元の順序を保つ
        var tokens: [TimedToken] = []
        for pieceTokens in perPiece {
            tokens.append(contentsOf: pieceTokens)
        }
        let ordered = tokens.enumerated().sorted { (lhs: (offset: Int, element: TimedToken),
                                                    rhs: (offset: Int, element: TimedToken)) -> Bool in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            return lhs.offset < rhs.offset
        }
        return ordered.map { $0.element }
    }

    // MARK: - まとめて送る経路(背景 URLSession)

    /// transcribeClips に渡す 1 クリップ分(元素材の範囲と、出力タイムラインへの対応づけ)
    struct ClipSource {
        let clipID: UUID
        let name: String
        let sourceURL: URL
        /// トリミング範囲(元素材上の秒)
        let sourceStart: Double
        let sourceEnd: Double
        let speed: Double
        /// 出力タイムライン上の開始・終了(秒)
        let timelineStart: Double
        let timelineEnd: Double
    }

    /// transcribeClips の進み具合
    struct BatchProgress {
        enum Phase {
            /// 音声の切り出し(completed / total は切り出しの単位数)
            case preparing
            /// 送信・認識(completed / total はピース数)
            case transcribing
        }

        let phase: Phase
        let completed: Int
        let total: Int
        /// 背景セッション(ロック中・アプリが止められた後も送信が続く)で送っているか
        let inBackgroundSession: Bool

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }
    }

    /// 複数クリップをまとめて認識し、clips と同じ順に「元素材上の秒のトークン列」を返す。
    /// 1. すべてのピースを先に切り出す(端末内の処理なので速い。最大 maxConcurrentPieces 本ずつ)
    /// 2. 1 つのジョブにまとめて CloudBackgroundUploader に預け、全ピースの応答がそろうまで待つ
    ///    (継続処理中にバックグラウンドで送り始めるとき・登録に失敗したときは、このプロセスから従来どおり送る)
    /// 3. 応答を従来と同じ解析・オフセット・範囲の丸めでトークンにする
    /// ジョブは成功・失敗・キャンセルのどの場合も最後に片付ける(アプリごと終了したときだけ残り、次回取り込める)。
    /// 作業フォルダを作れなければ CloudBackgroundUploaderError.unavailable(呼び出し側は transcribe へ)。
    /// progress はこの関数を呼んだタスク、または背景セッションのデリゲートのキューから呼ばれる(メインスレッドではない)
    func transcribeClips(_ clips: [ClipSource], language: String, localeIdentifier: String? = nil,
                         apiKey: String? = nil, quality: CloudTranscriptionQuality? = nil, projectID: UUID? = nil,
                         pauseReporter: BackgroundPauseReporter? = nil,
                         progress: @escaping (BatchProgress) -> Void) async throws -> [[TimedToken]] {
        let key = (apiKey ?? AppSettings.shared.cloudCredential).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudTranscriptionError.missingAPIKey }
        guard !clips.isEmpty else { throw CloudTranscriptionError.noAudio }
        // 切り出し・送信の途中でバックグラウンドへ入ったかを判定できるように、監視を始めておく
        await BackgroundEpoch.install()
        let resolvedQuality = quality ?? AppSettings.shared.cloudQuality
        let firstModel = Self.model(for: resolvedQuality)

        let uploader = CloudBackgroundUploader.shared
        let jobID = UUID()
        let directory: URL
        do {
            directory = try uploader.makeJobDirectory(for: jobID)
        } catch {
            throw CloudBackgroundUploaderError.unavailable(String(localized: "作業フォルダを作れません(\(error.localizedDescription))"))
        }
        defer { uploader.discard(jobID: jobID) }

        // 1. クリップごとの範囲をピースに分ける
        var plans: [PiecePlan] = []
        for (order, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.sourceURL)
            let assetDuration = try await asset.load(.duration).seconds
            let rangeStart = max(0, clip.sourceStart)
            var rangeEnd = clip.sourceEnd
            if assetDuration.isFinite, assetDuration > 0 { rangeEnd = min(rangeEnd, assetDuration) }
            guard rangeEnd.isFinite, rangeEnd > rangeStart + 0.05 else { continue }
            for range in Self.pieces(start: rangeStart, end: rangeEnd) {
                plans.append(PiecePlan(clipOrder: order, range: range))
            }
        }
        guard !plans.isEmpty else { throw CloudTranscriptionError.noAudio }

        // 2. すべてのピースを先に切り出す
        let prepared = try await prepareAll(plans, clips: clips, directory: directory,
                                            pauseReporter: pauseReporter) { done, total in
            progress(BatchProgress(phase: .preparing, completed: done, total: total, inBackgroundSession: false))
        }
        try Task.checkCancellation()

        // 3. ジョブの記録(あとから字幕を作り直せるだけの情報)
        var pieces: [CloudJobManifest.Piece] = []
        for (planIndex, plan) in plans.enumerated() {
            let clip = clips[plan.clipOrder]
            for item in prepared[planIndex] {
                pieces.append(CloudJobManifest.Piece(index: pieces.count, clipID: clip.clipID, clipOrder: plan.clipOrder,
                                                     sourceStart: item.range.start, sourceEnd: item.range.end,
                                                     extractStartOffset: item.startOffset,
                                                     extractDuration: item.duration,
                                                     audioFileName: item.fileName, model: firstModel))
            }
        }
        guard !pieces.isEmpty else { throw CloudTranscriptionError.noAudio }
        var clipInfos: [CloudJobManifest.ClipInfo] = []
        for (order, clip) in clips.enumerated() {
            clipInfos.append(CloudJobManifest.ClipInfo(clipID: clip.clipID, order: order, name: clip.name,
                                                       sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd,
                                                       speed: clip.speed, timelineStart: clip.timelineStart,
                                                       timelineEnd: clip.timelineEnd))
        }
        let manifest = CloudJobManifest(id: jobID, projectID: projectID, language: language,
                                        localeIdentifier: localeIdentifier, quality: resolvedQuality.rawValue,
                                        model: firstModel, fallbackModel: Self.fallbackModel,
                                        clips: clipInfos, pieces: pieces)

        // 4. 送信。継続処理が動いている間にバックグラウンドで背景セッションへ預けると、iOS が「任意のタイミング」扱いにして
        //    充電中・Wi-Fi まで後回しにすることがあるので、そのときはこのプロセスから直接送る
        let backgroundWorkAllowed = pauseReporter?.allowsBackgroundWork ?? false
        // 継続処理が動いている間にバックグラウンドで必要になった送り直し・フォールバックも、同じ理由でこのプロセスから送らせる
        var inProcessRetryGate: (() -> Bool)? = nil
        if let reporter = pauseReporter {
            inProcessRetryGate = { reporter.allowsBackgroundWork }
        }
        var enqueued = false
        if !(backgroundWorkAllowed && AppLifecycle.shared.isInBackground) {
            do {
                try uploader.enqueue(job: manifest, apiKey: key, inProcessRetriesWhile: inProcessRetryGate)
                enqueued = true
            } catch let error as CloudTranscriptionError {
                throw error
            } catch {
                // 背景セッションを使えない → このプロセスから送る
                enqueued = false
            }
        }

        if enqueued {
            progress(BatchProgress(phase: .transcribing, completed: 0, total: pieces.count, inBackgroundSession: true))
            let results = try await uploader.waitForCompletion(jobID: jobID) { done, total in
                progress(BatchProgress(phase: .transcribing, completed: done, total: total, inBackgroundSession: true))
            }
            try Task.checkCancellation()
            let finished = uploader.job(withID: jobID) ?? manifest
            return try Self.tokensByClipOrder(job: finished, results: results)
        }

        progress(BatchProgress(phase: .transcribing, completed: 0, total: pieces.count, inBackgroundSession: false))
        let parsed = try await uploadInProcess(pieces, directory: directory, language: language, apiKey: key,
                                               firstModel: firstModel, pauseReporter: pauseReporter) { done, total in
            progress(BatchProgress(phase: .transcribing, completed: done, total: total, inBackgroundSession: false))
        }
        try Task.checkCancellation()
        return try Self.assembleTokens(job: manifest, parsed: parsed)
    }

    /// ジョブの応答(ピース番号 → JSON)から、clips の順(ClipInfo.order)に元素材上の秒のトークン列を作る。
    /// 解析・オフセット・範囲の丸め・並べ方は transcribe と同じ。応答が欠けていれば badResponse
    static func tokensByClipOrder(job: CloudJobManifest, results: [Int: Data]) throws -> [[TimedToken]] {
        var parsed: [Int: ParsedTranscription] = [:]
        for piece in job.pieces {
            guard let data = results[piece.index] else { throw CloudTranscriptionError.badResponse }
            parsed[piece.index] = try parse(data)
        }
        return try assembleTokens(job: job, parsed: parsed)
    }

    private static func assembleTokens(job: CloudJobManifest,
                                       parsed: [Int: ParsedTranscription]) throws -> [[TimedToken]] {
        var perClip = [[TimedToken]](repeating: [], count: job.clips.count)
        for piece in job.pieces {
            guard let result = parsed[piece.index] else { throw CloudTranscriptionError.badResponse }
            guard piece.clipOrder >= 0, piece.clipOrder < perClip.count else { continue }
            let pieceTokens = makeTokens(from: result, pieceDuration: piece.extractDuration, language: job.language)
            // ピースの範囲の外に出た時刻は元素材上の秒でこのピースの範囲内に収める(transcribeRange と同じ)
            let offset = piece.extractStartOffset
            for token in pieceTokens {
                let s = min(max(offset + token.start, piece.sourceStart), piece.sourceEnd)
                let e = min(max(offset + token.end, s), piece.sourceEnd)
                perClip[piece.clipOrder].append(TimedToken(text: token.text, start: s, end: e))
            }
        }
        return perClip.map { Self.stableSortedByStart($0) }
    }

    /// 開始時刻順に並べる(同じ時刻なら元の順序を保つ)
    private static func stableSortedByStart(_ tokens: [TimedToken]) -> [TimedToken] {
        let ordered = tokens.enumerated().sorted { (lhs: (offset: Int, element: TimedToken),
                                                    rhs: (offset: Int, element: TimedToken)) -> Bool in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            return lhs.offset < rhs.offset
        }
        return ordered.map { $0.element }
    }

    /// 切り出しの単位(クリップ内の 1 範囲。サイズ超過なら切り出し時にさらに半分に分ける)
    private struct PiecePlan: Sendable {
        let clipOrder: Int
        let range: PieceRange
    }

    /// 切り出し済みの 1 ピース
    private struct PreparedPiece: Sendable {
        let range: PieceRange
        let startOffset: Double
        let duration: Double
        let fileName: String
    }

    private struct PreparedBatch: Sendable {
        let planIndex: Int
        let pieces: [PreparedPiece]
    }

    private struct ParsedPiece: Sendable {
        let index: Int
        let parsed: ParsedTranscription
    }

    /// plans をすべて切り出す(最大 maxConcurrentPieces 本ずつ)。plans と同じ順に返す
    private func prepareAll(_ plans: [PiecePlan], clips: [ClipSource], directory: URL,
                            pauseReporter: BackgroundPauseReporter?,
                            progress: @escaping (Int, Int) -> Void) async throws -> [[PreparedPiece]] {
        let total = plans.count
        let maxInFlight = max(1, Self.maxConcurrentPieces)
        progress(0, total)
        return try await withThrowingTaskGroup(of: PreparedBatch.self,
                                               returning: [[PreparedPiece]].self) { group in
            var collected = [[PreparedPiece]](repeating: [], count: total)
            var launched = 0
            var finished = 0
            while finished < total {
                try Task.checkCancellation()
                while launched < total, launched - finished < maxInFlight {
                    let planIndex = launched
                    let range = plans[planIndex].range
                    let sourceURL = clips[plans[planIndex].clipOrder].sourceURL
                    group.addTask {
                        let pieces = try await self.preparePieces(range, sourceURL: sourceURL, directory: directory,
                                                                  pauseReporter: pauseReporter, depth: 0)
                        return PreparedBatch(planIndex: planIndex, pieces: pieces)
                    }
                    launched += 1
                }
                guard let batch = try await group.next() else { break }
                collected[batch.planIndex] = batch.pieces
                finished += 1
                progress(finished, total)
            }
            return collected
        }
    }

    /// range を directory に切り出す。サイズ超過なら半分に分けて順に切り出す(transcribeRange と同じ基準)
    private func preparePieces(_ range: PieceRange, sourceURL: URL, directory: URL,
                               pauseReporter: BackgroundPauseReporter?, depth: Int) async throws -> [PreparedPiece] {
        try Task.checkCancellation()
        let fileName = "audio-\(UUID().uuidString).m4a"
        let fileURL = directory.appendingPathComponent(fileName)
        let extracted = try await extractPieceFile(range, sourceURL: sourceURL, to: fileURL, pauseReporter: pauseReporter)
        if extracted.fileSize <= Self.maxPieceBytes {
            return [PreparedPiece(range: range, startOffset: extracted.startOffset,
                                  duration: extracted.duration, fileName: fileName)]
        }
        try? FileManager.default.removeItem(at: fileURL)
        let length = range.end - range.start
        guard length > 20, depth < 6 else { throw CloudTranscriptionError.fileTooLarge }
        let mid = (range.start + range.end) / 2
        let firstHalf = try await preparePieces(PieceRange(start: range.start, end: mid), sourceURL: sourceURL,
                                                directory: directory, pauseReporter: pauseReporter, depth: depth + 1)
        let secondHalf = try await preparePieces(PieceRange(start: mid, end: range.end), sourceURL: sourceURL,
                                                 directory: directory, pauseReporter: pauseReporter, depth: depth + 1)
        return firstHalf + secondHalf
    }

    /// range を fileURL に切り出す。バックグラウンドへ入った間に失敗したら、戻ってから
    /// maxExtractionAttempts 回まで切り出し直す(extractPiece と同じ)
    private func extractPieceFile(_ range: PieceRange, sourceURL: URL, to fileURL: URL,
                                  pauseReporter: BackgroundPauseReporter?) async throws -> TranscriptionAudioExtractor.Output {
        var failures = 0
        while true {
            try Task.checkCancellation()
            let epochBefore = BackgroundEpoch.current
            do {
                return try await TranscriptionAudioExtractor.extract(from: sourceURL, start: range.start,
                                                                     end: range.end, to: fileURL,
                                                                     format: .m4a16kMono)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                failures += 1
                let interrupted = AppLifecycle.shared.isInBackground || BackgroundEpoch.current != epochBefore
                guard interrupted, failures < Self.maxExtractionAttempts else { throw error }
                try await AppForegroundWaiter.wait(reporter: pauseReporter)
            }
        }
    }

    /// 切り出し済みのピースをこのプロセスから送る(最大 maxConcurrentPieces 本ずつ。再試行・フォールバックは transcribePiece)
    private func uploadInProcess(_ pieces: [CloudJobManifest.Piece], directory: URL, language: String, apiKey: String,
                                 firstModel: String, pauseReporter: BackgroundPauseReporter?,
                                 progress: @escaping (Int, Int) -> Void) async throws -> [Int: ParsedTranscription] {
        let total = pieces.count
        let fallback = FallbackSwitch()
        let maxInFlight = max(1, Self.maxConcurrentPieces)
        return try await withThrowingTaskGroup(of: ParsedPiece.self,
                                               returning: [Int: ParsedTranscription].self) { group in
            var collected: [Int: ParsedTranscription] = [:]
            var launched = 0
            var finished = 0
            while finished < total {
                try Task.checkCancellation()
                while launched < total, launched - finished < maxInFlight {
                    let pieceIndex = pieces[launched].index
                    let fileURL = directory.appendingPathComponent(pieces[launched].audioFileName)
                    group.addTask {
                        let fileData: Data
                        do {
                            fileData = try Data(contentsOf: fileURL)
                        } catch {
                            throw CloudTranscriptionError.network(error.localizedDescription)
                        }
                        let parsed = try await self.transcribePiece(fileData: fileData, language: language,
                                                                    apiKey: apiKey, firstModel: firstModel,
                                                                    fallback: fallback, pauseReporter: pauseReporter)
                        return ParsedPiece(index: pieceIndex, parsed: parsed)
                    }
                    launched += 1
                }
                guard let result = try await group.next() else { break }
                collected[result.index] = result.parsed
                finished += 1
                progress(finished, total)
            }
            return collected
        }
    }

    // MARK: - ピース分割

    struct PieceRange {
        let start: Double
        let end: Double
    }

    private static func pieces(start: Double, end: Double) -> [PieceRange] {
        var result: [PieceRange] = []
        var s = start
        while s < end - 0.05 {
            var e = min(s + maxPieceSeconds, end)
            // 残りが 30 秒未満ならこのピースに含める(ピースが長くなりすぎない範囲で)
            if end - e < 30, end - s <= maxPieceSeconds * 1.1 { e = end }
            result.append(PieceRange(start: s, end: e))
            s = e
        }
        return result
    }

    /// 同時処理の 1 本分の結果(index はピース順)
    private struct PieceResult: Sendable {
        let index: Int
        let tokens: [TimedToken]
    }

    /// 「どれかのピースでフォールバックしたら、以降に送るピースも最初からフォールバックモデルを使う」ための共有フラグ
    private final class FallbackSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false

        var isOn: Bool {
            lock.lock()
            defer { lock.unlock() }
            return on
        }

        func turnOn() {
            lock.lock()
            on = true
            lock.unlock()
        }
    }

    /// 元素材の range を切り出して送信し、元素材上の秒のトークン列を返す。
    /// 一時ファイルは成功・失敗・キャンセルのどの場合も削除する。サイズ超過なら半分に分けて順に処理する
    private func transcribeRange(_ range: PieceRange, sourceURL: URL, language: String, apiKey: String,
                                 firstModel: String, fallback: FallbackSwitch,
                                 pauseReporter: BackgroundPauseReporter?, depth: Int) async throws -> [TimedToken] {
        try Task.checkCancellation()
        // バックグラウンド中(画面ロックなど)は新しいピースを始めない
        try await AppForegroundWaiter.wait(reporter: pauseReporter)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let piece = try await extractPiece(range, sourceURL: sourceURL, to: tempURL, pauseReporter: pauseReporter)
        let extracted = piece.output

        guard let fileData = piece.data else {
            // サイズ超過 → 半分に分けて順に処理する
            try? FileManager.default.removeItem(at: tempURL)
            let length = range.end - range.start
            guard length > 20, depth < 6 else { throw CloudTranscriptionError.fileTooLarge }
            let mid = (range.start + range.end) / 2
            let firstHalf = try await transcribeRange(PieceRange(start: range.start, end: mid), sourceURL: sourceURL,
                                                      language: language, apiKey: apiKey, firstModel: firstModel,
                                                      fallback: fallback, pauseReporter: pauseReporter,
                                                      depth: depth + 1)
            let secondHalf = try await transcribeRange(PieceRange(start: mid, end: range.end), sourceURL: sourceURL,
                                                       language: language, apiKey: apiKey, firstModel: firstModel,
                                                       fallback: fallback, pauseReporter: pauseReporter,
                                                       depth: depth + 1)
            return firstHalf + secondHalf
        }

        try? FileManager.default.removeItem(at: tempURL)
        try Task.checkCancellation()

        let parsed = try await transcribePiece(fileData: fileData, language: language, apiKey: apiKey,
                                               firstModel: firstModel, fallback: fallback,
                                               pauseReporter: pauseReporter)
        try Task.checkCancellation()

        let pieceTokens = Self.makeTokens(from: parsed, pieceDuration: extracted.duration, language: language)
        // ピースの範囲の外に出た時刻(末尾のはみ出しなど)は元素材上の秒でこのピースの範囲内に収め、
        // ピース間で順序が入れ替わらないようにする(先頭サンプルの時刻が range.start とずれていても隣のピースに食い込まない)
        let offset = extracted.startOffset
        return pieceTokens.map { token in
            let s = min(max(offset + token.start, range.start), range.end)
            let e = min(max(offset + token.end, s), range.end)
            return TimedToken(text: token.text, start: s, end: e)
        }
    }

    /// range を tempURL に切り出して読み込む。サイズ超過なら data は nil(呼び出し側で半分に分ける)。
    /// 画面ロックなどでバックグラウンドへ入った間に切り出し・読み込みが失敗したときは、フォアグラウンドに戻ってから
    /// maxExtractionAttempts 回まで切り出し直す。それ以外の失敗は従来どおりそのまま投げる
    private func extractPiece(_ range: PieceRange, sourceURL: URL, to tempURL: URL,
                              pauseReporter: BackgroundPauseReporter?) async throws -> (output: TranscriptionAudioExtractor.Output, data: Data?) {
        var failures = 0
        while true {
            try Task.checkCancellation()
            let epochBefore = BackgroundEpoch.current
            do {
                let extracted = try await TranscriptionAudioExtractor.extract(from: sourceURL, start: range.start,
                                                                              end: range.end, to: tempURL,
                                                                              format: .m4a16kMono)
                if extracted.fileSize > Self.maxPieceBytes {
                    return (output: extracted, data: nil)
                }
                let fileData: Data
                do {
                    fileData = try Data(contentsOf: tempURL)
                } catch {
                    throw CloudTranscriptionError.network(error.localizedDescription)
                }
                return (output: extracted, data: fileData)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                failures += 1
                let interrupted = AppLifecycle.shared.isInBackground || BackgroundEpoch.current != epochBefore
                guard interrupted, failures < Self.maxExtractionAttempts else { throw error }
                // バックグラウンドへ入ったことで中断された可能性がある → 戻るまで待って切り出し直す
                try await AppForegroundWaiter.wait(reporter: pauseReporter)
            }
        }
    }

    // MARK: - リクエスト

    private enum ModelKind {
        case whisper   // verbose_json + 単語/セグメント時刻
        case diarize   // diarized_json(セグメント時刻)
        case plain     // json(本文のみ)
    }

    private static func kind(of model: String) -> ModelKind {
        if model.hasPrefix("whisper") { return .whisper }
        if model.contains("diarize") { return .diarize }
        return .plain
    }

    /// 1 ピース分の音声を送り、解析結果を返す。
    /// - 一時的な通信エラー: 送信中にバックグラウンドへ入っていた(今バックグラウンド中、または送信の前後で BackgroundEpoch が変わった)なら、
    ///   フォアグラウンドに戻るまで待って送り直す(回数に数えない)。
    ///   フォアグラウンドなら 2・4・8・16 秒おいて送り直し、合計 TransientNetworkRetry.maxAttempts 回失敗したら
    ///   従来どおりのエラー(offline / timedOut / network)を投げる
    /// - 429 / 5xx は再試行、モデル非対応の 4xx はフォールバック
    private func transcribePiece(fileData: Data, language: String, apiKey: String,
                                 firstModel: String, fallback: FallbackSwitch,
                                 pauseReporter: BackgroundPauseReporter?) async throws -> ParsedTranscription {
        // 他のピースですでにフォールバックしていれば、最初からフォールバックモデルを使う
        var model = fallback.isOn ? Self.fallbackModel : firstModel
        /// HTTP 応答を受け取った回数(429 / 5xx の再試行判定用)
        var attempt = 0
        /// フォアグラウンドで起きた一時的な通信エラーの回数
        var networkFailures = 0

        while true {
            try Task.checkCancellation()
            // 画面ロック中などは新しい送信を始めず、フォアグラウンドに戻るまで待つ
            try await AppForegroundWaiter.wait(reporter: pauseReporter)

            // 送信のたびに読み直す(前後で変わったら、この送信の間にバックグラウンドへ入った)
            let epochBefore = BackgroundEpoch.current
            let outcome = try await send(fileData: fileData, model: model, language: language, apiKey: apiKey)
            let status: Int
            let data: Data
            switch outcome {
            case .response(let receivedStatus, let receivedData):
                status = receivedStatus
                data = receivedData
            case .transientFailure(let urlError):
                // 継続処理が動いている間はバックグラウンドでもアプリは止まらないので、フォアグラウンドと同じく回数に数える
                // (数えないと、オフラインのまま空回りする)
                let backgroundWorkAllowed = pauseReporter?.allowsBackgroundWork ?? false
                if !backgroundWorkAllowed,
                   (AppLifecycle.shared.isInBackground || BackgroundEpoch.current != epochBefore) {
                    // 画面ロックなどで切れた(戻ってから失敗が届いた場合も含む)
                    // → ループの先頭で戻るまで待ち、同じピースを送り直す(回数に数えない)
                    continue
                }
                networkFailures += 1
                if networkFailures >= TransientNetworkRetry.maxAttempts {
                    throw Self.finalError(for: urlError)
                }
                try await Task.sleep(nanoseconds: TransientNetworkRetry.delayNanoseconds(afterFailures: networkFailures))
                continue
            }
            attempt += 1

            if (200..<300).contains(status) {
                return try Self.parse(data)
            }

            let apiError = Self.apiError(from: data)
            switch status {
            case 401:
                throw CloudTranscriptionError.invalidAPIKey
            case 413:
                throw CloudTranscriptionError.fileTooLarge
            case 429:
                let quotaExhausted = apiError.code.contains("insufficient_quota")
                    || apiError.message.lowercased().contains("quota")
                if !quotaExhausted, attempt < 3 {
                    // 同時に送っているピースが一斉に再送しないよう、少しずらす
                    let base = UInt64(attempt) * 3_000_000_000
                    let jitter = UInt64.random(in: 0...1_000_000_000)
                    try await Task.sleep(nanoseconds: base + jitter)
                    continue
                }
                let detail: String
                if quotaExhausted {
                    detail = String(localized: "OpenAI の残高(クレジット)が不足している可能性があります。")
                } else {
                    detail = String(localized: "しばらく待ってからもう一度お試しください。")
                }
                throw CloudTranscriptionError.rateLimited(detail)
            case 400, 404, 415, 422:
                if model != Self.fallbackModel, Self.isModelCompatibilityError(apiError) {
                    // モデルが使えない/形式非対応 → フォールバックへ(以降に送るピースもこちら)
                    model = Self.fallbackModel
                    fallback.turnOn()
                    attempt = 0
                    continue
                }
                throw CloudTranscriptionError.server(status: status, message: apiError.message.isEmpty ? String(localized: "リクエストが拒否されました") : apiError.message)
            case 500...599:
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                throw CloudTranscriptionError.server(status: status, message: apiError.message.isEmpty ? String(localized: "一時的な障害です") : apiError.message)
            default:
                throw CloudTranscriptionError.server(status: status, message: apiError.message.isEmpty ? String(localized: "不明なエラー") : apiError.message)
            }
        }
    }

    /// send の結果
    private enum SendOutcome {
        /// HTTP 応答を受け取った(ステータスは問わない)
        case response(status: Int, data: Data)
        /// 一時的な通信エラー(送り直せば通る見込みがある)
        case transientFailure(URLError)
    }

    /// multipart POST。リクエストは呼ぶたびに作り直す(再試行のたびにアップロードし直す)。
    /// 一時的な通信エラーは .transientFailure で返し、それ以外の通信エラーは CloudTranscriptionError に変換して投げる。
    /// こちらからのキャンセル(Task のキャンセル)は CancellationError
    private func send(fileData: Data, model: String, language: String, apiKey: String) async throws -> SendOutcome {
        let body = Self.multipartBody(audioData: fileData, model: model, language: language)
        let request = Self.makeUploadRequest(apiKey: apiKey, contentType: body.contentType, model: model)

        do {
            let (data, response) = try await session.upload(for: request, from: body.data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .response(status: status, data: data)
        } catch let error as URLError {
            // こちらからのキャンセル(利用者の中止・ほかのピースの失敗)
            if Task.isCancelled { throw CancellationError() }
            // Task がキャンセルされていない .cancelled は、画面ロックなどでシステムが通信を打ち切ったもの → 一時的
            if TransientNetworkRetry.isTransient(error) { return .transientFailure(error) }
            throw Self.finalError(for: error)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // 画面ロックなどで通信が打ち切られると、URLError ではなく NSPOSIXErrorDomain(53 など)で届くことがある → 一時的
            if TransientNetworkRetry.isTransient(error) { return .transientFailure(URLError(.networkConnectionLost)) }
            throw CloudTranscriptionError.network(error.localizedDescription)
        }
    }

    /// 再試行しない(または再試行を使い切った)通信エラーを利用者向けのエラーにする
    private static func finalError(for error: URLError) -> CloudTranscriptionError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .network(error.localizedDescription)
        }
    }

    // MARK: - 送信内容(このプロセスからの送信と背景セッションで共用)

    /// 1 ピース分の multipart 本文と Content-Type(boundary 付き)
    static func multipartBody(audioData: Data, model: String, language: String) -> (contentType: String, data: Data) {
        var body = MultipartBody()
        body.addField("model", model)
        body.addField("language", language)
        switch kind(of: model) {
        case .whisper:
            body.addField("response_format", "verbose_json")
            body.addField("timestamp_granularities[]", "word")
            body.addField("timestamp_granularities[]", "segment")
            body.addField("temperature", "0")
        case .diarize:
            body.addField("response_format", "diarized_json")
            body.addField("chunking_strategy", "auto")
        case .plain:
            body.addField("response_format", "json")
            body.addField("chunking_strategy", "auto")
        }
        // 日本語: 句読点・かな漢字の書き方を例示して、ローマ字(hun? など)や句読点なしの出力を防ぐ。
        // diarize モデルは prompt 非対応のため送らない
        if let prompt = transcriptionPrompt(language: language), kind(of: model) != .diarize {
            body.addField("prompt", prompt)
        }
        body.addFile(name: "file", filename: "audio.m4a", mimeType: "audio/m4a", fileData: audioData)
        return (contentType: "multipart/form-data; boundary=\(body.boundary)", data: body.finished())
    }

    /// 認識モデルに渡す文体の例(prompt)。英語などは nil(送らない)
    static func transcriptionPrompt(language: String) -> String? {
        guard language.lowercased().hasPrefix("ja") else { return nil }
        return String(localized: "こんにちは。今日はよろしくお願いします。では、始めましょう。")
    }

    /// 1 リクエストの待ち時間の上限。whisper-1 は 120 秒、精度優先モデルは 240 秒
    static func requestTimeout(for model: String) -> TimeInterval {
        kind(of: model) == .whisper ? whisperRequestTimeout : accurateRequestTimeout
    }

    /// 本文を含まない POST リクエスト(本文は upload(for:from:) / uploadTask(with:fromFile:) で渡す)
    static func makeUploadRequest(apiKey: String, contentType: String, model: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout(for: model)
        return request
    }

    // MARK: - 背景セッションの応答の判定(CloudBackgroundUploader から使う)

    /// 背景セッションで 1 回送った結果の扱い
    enum UploadDisposition {
        /// 2xx(応答を結果として保存する)
        case success
        /// 同じ送信内容で送り直す(秒数はそれまで待つ時間)
        case retry(Double)
        /// 精度優先モデルが使えない → フォールバックモデル(whisper-1)で作り直して送る
        case useFallbackModel
        /// ジョブ全体を失敗にする
        case fail(CloudTranscriptionError)
    }

    /// HTTP 応答の扱い。attempt はこのピースで送信を始めた回数(今回を含む)。
    /// このプロセスからの送信(transcribePiece)と同じ基準で、429 / 5xx の再試行だけ maxAttempts 回まで
    static func disposition(forStatus status: Int, data: Data, model: String,
                            attempt: Int, maxAttempts: Int) -> UploadDisposition {
        if (200..<300).contains(status) { return .success }
        let apiError = Self.apiError(from: data)
        switch status {
        case 401:
            return .fail(.invalidAPIKey)
        case 403:
            return .fail(.server(status: status, message: apiError.message.isEmpty ? String(localized: "アクセスが拒否されました") : apiError.message))
        case 413:
            return .fail(.fileTooLarge)
        case 429:
            let quotaExhausted = apiError.code.contains("insufficient_quota")
                || apiError.message.lowercased().contains("quota")
            if quotaExhausted {
                return .fail(.rateLimited(String(localized: "OpenAI の残高(クレジット)が不足している可能性があります。")))
            }
            if attempt < maxAttempts {
                // 同時に送っているピースが一斉に再送しないよう、少しずらす
                let base = Double(min(attempt, 5)) * 3
                return .retry(base + Double.random(in: 0...1))
            }
            return .fail(.rateLimited(String(localized: "しばらく待ってからもう一度お試しください。")))
        case 400, 404, 415, 422:
            if model != fallbackModel, isModelCompatibilityError(apiError) {
                return .useFallbackModel
            }
            return .fail(.server(status: status, message: apiError.message.isEmpty ? String(localized: "リクエストが拒否されました") : apiError.message))
        case 500...599:
            if attempt < maxAttempts {
                return .retry(Double(min(attempt, 4)) * 2)
            }
            return .fail(.server(status: status, message: apiError.message.isEmpty ? String(localized: "一時的な障害です") : apiError.message))
        default:
            return .fail(.server(status: status, message: apiError.message.isEmpty ? String(localized: "不明なエラー") : apiError.message))
        }
    }

    /// 通信エラー(応答なし)の扱い。一時的なもの(タイムアウト・回線切れ・システムによる打ち切り・
    /// NSPOSIXErrorDomain 53/54/57 など)は maxAttempts 回まで 2・4・8・16 秒おいて送り直す。
    /// こちらから取り消したタスクは呼び出し側で除いておくこと
    static func disposition(forTransportError error: Error, attempt: Int, maxAttempts: Int) -> UploadDisposition {
        let urlError = error as? URLError
        guard TransientNetworkRetry.isTransient(error) else {
            if let urlError { return .fail(finalError(for: urlError)) }
            return .fail(.network(error.localizedDescription))
        }
        if attempt < maxAttempts {
            let nanoseconds = TransientNetworkRetry.delayNanoseconds(afterFailures: max(1, attempt))
            return .retry(Double(nanoseconds) / 1_000_000_000)
        }
        if let urlError { return .fail(finalError(for: urlError)) }
        return .fail(.offline)
    }

    // MARK: - エラー応答

    private struct APIError {
        var message: String = ""
        var type: String = ""
        var param: String = ""
        var code: String = ""
    }

    private static func apiError(from data: Data) -> APIError {
        var result = APIError()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8) {
                result.message = String(text.prefix(200))
            }
            return result
        }
        if let error = root["error"] as? [String: Any] {
            result.message = error["message"] as? String ?? ""
            result.type = error["type"] as? String ?? ""
            result.param = error["param"] as? String ?? ""
            result.code = error["code"] as? String ?? ""
        } else if let message = root["message"] as? String {
            result.message = message
        }
        return result
    }

    /// 「モデルが無い / このモデルでは response_format 等が使えない」系の 4xx か
    private static func isModelCompatibilityError(_ error: APIError) -> Bool {
        let code = error.code.lowercased()
        let param = error.param.lowercased()
        let message = error.message.lowercased()
        if code.contains("model_not_found") || code.contains("unsupported") || code.contains("invalid_value") { return true }
        if ["model", "response_format", "chunking_strategy", "timestamp_granularities", "timestamp_granularities[]", "language"].contains(param) { return true }
        if message.contains("response_format") || message.contains("chunking_strategy") { return true }
        if message.contains("not supported") || message.contains("unsupported") || message.contains("does not support") { return true }
        if message.contains("model") && (message.contains("does not exist") || message.contains("not found") || message.contains("do not have access") || message.contains("invalid")) { return true }
        return false
    }

    // MARK: - 応答の解析

    fileprivate struct RawWord {
        let text: String
        let start: Double
        let end: Double
    }

    fileprivate struct RawSegment {
        let text: String
        let start: Double
        let end: Double
    }

    fileprivate struct ParsedTranscription {
        var text: String
        var duration: Double?
        var words: [RawWord]
        var segments: [RawSegment]
    }

    private static func parse(_ data: Data) throws -> ParsedTranscription {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return ParsedTranscription(text: text, duration: nil, words: [], segments: [])
            }
            throw CloudTranscriptionError.badResponse
        }
        var text = (root["text"] as? String) ?? ""
        let duration = number(root["duration"])

        var words: [RawWord] = []
        if let rawWords = root["words"] as? [[String: Any]] {
            for raw in rawWords {
                guard let word = raw["word"] as? String,
                      let start = number(raw["start"]), let end = number(raw["end"]) else { continue }
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                words.append(RawWord(text: trimmed, start: start, end: max(start, end)))
            }
        }

        var segments: [RawSegment] = []
        // whisper-1 が「無音」と判定したセグメント(no_speech_prob > 0.6 かつ avg_logprob < -1、Whisper 本家と同じ基準)。
        // 無音区間で出る幻聴(「ご視聴ありがとうございました」など)を捨てるのに使う。diarized_json には無い項目なので影響しない
        var silentSegments: [RawSegment] = []
        if let rawSegments = root["segments"] as? [[String: Any]] {
            for raw in rawSegments {
                guard let segmentText = raw["text"] as? String,
                      let start = number(raw["start"]), let end = number(raw["end"]) else { continue }
                let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let segment = RawSegment(text: trimmed, start: start, end: max(start, end))
                let noSpeech: Double = number(raw["no_speech_prob"]) ?? 0
                let avgLogprob: Double = number(raw["avg_logprob"]) ?? 0
                if noSpeech > 0.6 && avgLogprob < -1.0 {
                    silentSegments.append(segment)
                } else {
                    segments.append(segment)
                }
            }
        }
        if !silentSegments.isEmpty {
            words = words.filter { word in
                let mid = (word.start + word.end) / 2
                return !silentSegments.contains { mid >= $0.start && mid <= $0.end }
            }
            // 残ったセグメントが無ければ本文全体も幻聴とみなす(本文の均等配分に落ちないように)
            if segments.isEmpty { text = "" }
        }
        words.sort { $0.start < $1.start }
        segments.sort { $0.start < $1.start }
        return ParsedTranscription(text: text, duration: duration, words: words, segments: segments)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    // MARK: - トークン化(ピース先頭からの秒)

    private static func makeTokens(from parsed: ParsedTranscription, pieceDuration: Double, language: String) -> [TimedToken] {
        if !parsed.words.isEmpty {
            if parsed.segments.isEmpty {
                return parsed.words.map { TimedToken(text: $0.text, start: $0.start, end: $0.end) }
            }
            return alignedTokens(words: parsed.words, segments: parsed.segments, language: language)
        }
        if !parsed.segments.isEmpty {
            var result: [TimedToken] = []
            for segment in parsed.segments {
                result.append(contentsOf: TranscriptionTokenUtilities.distributeEvenly(
                    text: segment.text, start: segment.start, end: segment.end, language: language))
            }
            return result
        }
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let duration = parsed.duration ?? pieceDuration
        return TranscriptionTokenUtilities.distributeEvenly(text: text, start: 0, end: max(0.5, duration), language: language)
    }

    /// 単語(句読点なし)にセグメント本文の句読点を貼り付ける(whisper-1 の verbose_json 用)
    private static func alignedTokens(words: [RawWord], segments: [RawSegment], language: String) -> [TimedToken] {
        var result: [TimedToken] = []
        var wordIndex = 0
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            var segmentWords: [RawWord] = []
            while wordIndex < words.count {
                let word = words[wordIndex]
                let mid = (word.start + word.end) / 2
                if isLast || mid < segment.end + 0.02 {
                    segmentWords.append(word)
                    wordIndex += 1
                } else {
                    break
                }
            }
            if segmentWords.isEmpty {
                result.append(contentsOf: TranscriptionTokenUtilities.distributeEvenly(
                    text: segment.text, start: segment.start, end: segment.end, language: language))
            } else {
                result.append(contentsOf: attachPunctuation(segmentText: segment.text, words: segmentWords))
            }
        }
        while wordIndex < words.count {
            let word = words[wordIndex]
            result.append(TimedToken(text: word.text, start: word.start, end: word.end))
            wordIndex += 1
        }
        return result
    }

    private static let openingMarks: Set<Unicode.Scalar> = [
        "「", "『", "（", "(", "“", "‘", "【", "〔", "[", "〈", "《", "｢",
    ]

    private static func isPunctuationScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .otherPunctuation, .openPunctuation, .closePunctuation, .dashPunctuation,
             .initialPunctuation, .finalPunctuation, .connectorPunctuation,
             .otherSymbol, .mathSymbol, .currencySymbol, .modifierSymbol:
            return true
        default:
            return false
        }
    }

    private static func scalarEquals(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if a == b { return true }
        return String(a).lowercased() == String(b).lowercased()
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ core: [Unicode.Scalar]) -> Bool {
        guard !core.isEmpty, index >= 0, index + core.count <= scalars.count else { return false }
        for k in 0..<core.count where !scalarEquals(scalars[index + k], core[k]) {
            return false
        }
        return true
    }

    private static func search(_ scalars: [Unicode.Scalar], from: Int, _ core: [Unicode.Scalar], limit: Int) -> Int? {
        guard !core.isEmpty else { return nil }
        var i = max(0, from)
        let maxStart = min(scalars.count - core.count, from + limit)
        while i <= maxStart {
            if matches(scalars, at: i, core) { return i }
            i += 1
        }
        return nil
    }

    private static func attachPunctuation(segmentText: String, words: [RawWord]) -> [TimedToken] {
        let scalars = Array(segmentText.unicodeScalars)
        var cursor = 0
        var out: [TimedToken] = []
        var mismatches = 0

        for word in words {
            let core = Array(word.text.unicodeScalars).filter { !$0.properties.isWhitespace }
            var text = String(String.UnicodeScalarView(core))

            while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
            var prefix = String.UnicodeScalarView()
            var probe = cursor
            while probe < scalars.count, openingMarks.contains(scalars[probe]) {
                prefix.append(scalars[probe])
                probe += 1
            }

            var matchedAt: Int? = nil
            if matches(scalars, at: probe, core) {
                matchedAt = probe
            } else if let found = search(scalars, from: cursor, core, limit: 12) {
                matchedAt = found
                prefix = String.UnicodeScalarView()
                mismatches += 1
            } else {
                mismatches += 1
            }

            if let at = matchedAt {
                var end = at + core.count
                var suffix = String.UnicodeScalarView()
                while end < scalars.count, isPunctuationScalar(scalars[end]), !openingMarks.contains(scalars[end]) {
                    suffix.append(scalars[end])
                    end += 1
                }
                text = String(prefix) + String(String.UnicodeScalarView(core)) + String(suffix)
                cursor = end
            }

            if !text.isEmpty {
                out.append(TimedToken(text: text, start: word.start, end: word.end))
            }
        }

        if mismatches * 2 > words.count {
            // ずれが大きい → 句読点なしの単語をそのまま返す
            return words.map { TimedToken(text: $0.text, start: $0.start, end: $0.end) }
        }
        return out
    }
}

// MARK: - multipart/form-data

private struct MultipartBody {
    let boundary = "VideoManiaBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private(set) var data = Data()

    mutating func addField(_ name: String, _ value: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, fileData: Data) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        appendString("\r\n")
    }

    func finished() -> Data {
        var result = data
        if let tail = "--\(boundary)--\r\n".data(using: .utf8) {
            result.append(tail)
        }
        return result
    }

    private mutating func appendString(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            data.append(encoded)
        }
    }
}

// MARK: - 共通ユーティリティ(時刻の均等配分)

enum TranscriptionTokenUtilities {
    /// NLTokenizer の単語に直後の句読点・記号を付けた断片列。language は "ja" / "en" など
    static func wordPieces(_ text: String, language: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(language.lowercased().hasPrefix("ja") ? .japanese : .english)
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard !ranges.isEmpty else { return [] }
        var pieces: [String] = []
        for (i, range) in ranges.enumerated() {
            let lower = (i == 0) ? text.startIndex : range.lowerBound
            let upper = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : text.endIndex
            guard lower < upper else { continue }
            let piece = String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces
    }

    /// text を単語断片に分け、start〜end を文字数比で配分したトークン列を返す
    static func distributeEvenly(text: String, start: Double, end: Double, language: String) -> [TimedToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let safeEnd = max(start, end)
        let pieces = wordPieces(trimmed, language: language)
        guard !pieces.isEmpty else { return [TimedToken(text: trimmed, start: start, end: safeEnd)] }
        let weights = pieces.map { Double(max(1, $0.count)) }
        let total = max(1, weights.reduce(0, +))
        let span = safeEnd - start
        var cursor = start
        var result: [TimedToken] = []
        result.reserveCapacity(pieces.count)
        for (i, piece) in pieces.enumerated() {
            let pieceEnd = (i == pieces.count - 1) ? safeEnd : min(safeEnd, cursor + span * weights[i] / total)
            result.append(TimedToken(text: piece, start: cursor, end: pieceEnd))
            cursor = pieceEnd
        }
        return result
    }
}

// MARK: - 一時的な通信エラーとバックグラウンド待ち(クラウド文字起こし・Whisper・字幕の AI 仕上げで共用)

/// バックグラウンド待ち(一時停止)の開始・終了を通知する。
/// 同時に複数のピースが待っても、最初に待ち始めたときと最後に待ち終えたときだけ onChange を呼ぶ。
/// onChange はどのスレッドから呼ばれるか決まっていないので、受け取った側は表示を変える時点で isPaused を読み直すこと
final class BackgroundPauseReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = 0
    private var backgroundWorkAllowed = false
    private let onChange: (BackgroundPauseReporter) -> Void

    init(onChange: @escaping (BackgroundPauseReporter) -> Void) {
        self.onChange = onChange
    }

    /// 今バックグラウンド待ちをしている処理があるか
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting > 0
    }

    /// true の間は、この reporter を渡された処理はバックグラウンドでもフォアグラウンド待ちをしない
    /// (iOS 26+ の継続処理が動いていて、ロック中もアプリが止められないとき。TranscriptionService が設定する)。
    /// Whisper(GPU / Neural Engine)にはこれを true にしない reporter を渡すこと
    var allowsBackgroundWork: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return backgroundWorkAllowed
        }
        set {
            lock.lock()
            backgroundWorkAllowed = newValue
            lock.unlock()
        }
    }

    fileprivate func begin() {
        lock.lock()
        waiting += 1
        let changed = waiting == 1
        lock.unlock()
        if changed { onChange(self) }
    }

    fileprivate func end() {
        lock.lock()
        let changed = waiting == 1
        if waiting > 0 { waiting -= 1 }
        lock.unlock()
        if changed { onChange(self) }
    }
}

/// アプリがフォアグラウンドに戻るのを待つ。
/// 画面ロック中(バックグラウンド)は通信が切られ、CoreML の GPU / Neural Engine も使えないため
enum AppForegroundWaiter {
    /// reporter.allowsBackgroundWork のときにバックグラウンドで通すまでの間(失敗 → 再試行が空回りしないように)
    private static let backgroundPassDelayNanoseconds: UInt64 = 1_000_000_000

    /// バックグラウンドにいる間、0.5 秒ごとに確認して待つ。フォアグラウンドならすぐに戻る。
    /// 待っている間は reporter に一時停止中と伝える。キャンセルされたら CancellationError を投げる。
    /// reporter.allowsBackgroundWork が true(継続処理が動いている)なら待たずに戻る(1 秒だけ間をあける)
    static func wait(reporter: BackgroundPauseReporter? = nil) async throws {
        guard AppLifecycle.shared.isInBackground else { return }
        if let reporter, reporter.allowsBackgroundWork {
            try await Task.sleep(nanoseconds: backgroundPassDelayNanoseconds)
            try Task.checkCancellation()
            return
        }
        reporter?.begin()
        defer { reporter?.end() }
        while AppLifecycle.shared.isInBackground {
            try Task.checkCancellation()
            if let reporter, reporter.allowsBackgroundWork { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try Task.checkCancellation()
    }
}

/// 送り直せば通る見込みのある通信エラーと、その再試行の間隔
enum TransientNetworkRetry {
    /// 1 リクエスト(ピース / バッチ)あたりの試行回数の上限。バックグラウンド待ちの後の送り直しは数えない
    static let maxAttempts = 6

    /// 再試行までの待ち時間(秒)。これより後は最後の値を使う
    private static let delaySeconds: [UInt64] = [2, 4, 8, 16]

    /// 一時的な通信エラーか。
    /// .cancelled は Task がキャンセルされていないとき(画面ロックなどでシステムが通信を打ち切ったとき)だけ渡すこと
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected, .cancelled:
            return true
        default:
            return false
        }
    }

    /// 一時的な通信エラーか(URLError 以外も含む)。
    /// 通信中に画面ロックなどでアプリが止まると、URLError ではなく NSPOSIXErrorDomain のエラー
    /// (53「Software caused connection abort」・54 接続リセット・57 未接続など)で届くことがあるので、それも一時的とみなす。
    /// URLError の .cancelled の扱いは isTransient(_: URLError) と同じ(Task がキャンセルされていないときだけ渡すこと)
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return isTransient(urlError)
        }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && transientPOSIXCodes.contains(nsError.code)
    }

    /// ENETDOWN(50)・ECONNABORTED(53)・ECONNRESET(54)・ENOTCONN(57)・ETIMEDOUT(60)
    private static let transientPOSIXCodes: Set<Int> = [50, 53, 54, 57, 60]

    /// failures 回目の失敗の後に待つ時間(ナノ秒)。2・4・8・16 秒、以降は 16 秒
    static func delayNanoseconds(afterFailures failures: Int) -> UInt64 {
        let index = min(max(failures, 1), delaySeconds.count) - 1
        return delaySeconds[index] * 1_000_000_000
    }
}

/// アプリがバックグラウンドへ入った回数(didEnterBackground の通知ごとに 1 増える。どのスレッドからでも読める)。
/// 処理の前後で値を比べると、その間にバックグラウンドへ入ったかがわかる
/// (画面ロックで一時停止し、フォアグラウンドに戻ってから失敗が届いた場合も含む)。
/// 通知の監視は最初の install() で始めるので、各処理の開始時(フォアグラウンド中)に呼ぶこと
enum BackgroundEpoch {
    private static let lock = NSLock()
    private static var count = 0
    private static var observer: NSObjectProtocol?

    /// 今の値
    static var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// 通知の監視を始める(2 回目以降は何もしない)
    static func install() async {
        if isInstalled { return }
        await MainActor.run {
            BackgroundEpoch.installOnMainActor()
        }
    }

    private static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observer != nil
    }

    @MainActor
    private static func installOnMainActor() {
        if isInstalled { return }
        let token = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                           object: nil, queue: nil) { _ in
            BackgroundEpoch.increment()
        }
        lock.lock()
        observer = token
        lock.unlock()
    }

    private static func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
