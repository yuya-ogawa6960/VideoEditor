import AVFoundation

/// 音の出し方の設定。
/// 何もしないと iOS の既定(.soloAmbient)になり、サイレントスイッチ(マナーモード)で動画の音が鳴らない。
/// 動画編集アプリなので、マナーモードでも再生の音が聞こえる .playback にしておく(起動時・前面に戻ったとき・再生の直前)。
enum AudioSessionSetup {
    /// 再生用(.playback)にする。すでにそうなら何もしない。録音中(.playAndRecord。VoiceRecorder が設定)は触らない
    static func ensurePlayback() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback, session.category != .playAndRecord else { return }
        try? session.setCategory(.playback, mode: .default, options: [])
    }
}
