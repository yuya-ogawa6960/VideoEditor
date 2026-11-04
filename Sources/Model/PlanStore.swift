import Foundation
import Observation
import StoreKit

// =====================================================================
// アプリ内課金のプラン(Starter 無料 / Standard / Pro。自動更新サブスクリプション)。
//
// - 使えるかどうかは StoreKit 2 の「いま有効な購入」(Transaction.currentEntitlements)で決める。
//   サインインしていなくても、オフラインでも、買ったプランの機能(画質・長さ・広告なし・有料の機能)は使える
// - サインインしていれば、有効な購入の記録(JWS)をサーバー(/v1/subscription/sync)に送り、毎月のポイントを受け取る
// - プランの条件(PlanTerms)は、プラン設定のページ(tiers/current の plans)とそろえる
// - 商品 ID は App Store Connect のサブスクリプションと、server/src/subscriptions.js の PRODUCTS と同じにする
// =====================================================================

/// プラン(上ほど使える機能が多い)
enum PlanTier: String, CaseIterable, Comparable {
    case free, standard, pro

    private var rank: Int {
        switch self {
        case .free: return 0
        case .standard: return 1
        case .pro: return 2
        }
    }

    static func < (lhs: PlanTier, rhs: PlanTier) -> Bool { lhs.rank < rhs.rank }

    var displayName: String {
        switch self {
        case .free: return String(localized: "Starter(無料)")
        case .standard: return "Standard"
        case .pro: return "Pro"
        }
    }
}

/// プランごとの条件
struct PlanTerms {
    /// 書き出しの最高画質
    let maxResolution: ResolutionCap
    /// 書き出せる長さ(分)。nil は無制限
    let maxMinutes: Int?
    /// 広告を出すか
    let showsAds: Bool
    /// 毎月のポイント(サーバーが付ける。表示用)
    let monthlyPoints: Int

    static func terms(for tier: PlanTier) -> PlanTerms {
        switch tier {
        case .free: return PlanTerms(maxResolution: .hd720, maxMinutes: 5, showsAds: true, monthlyPoints: 0)
        case .standard: return PlanTerms(maxResolution: .fhd1080, maxMinutes: 10, showsAds: false, monthlyPoints: 1500)
        case .pro: return PlanTerms(maxResolution: .uhd4k, maxMinutes: nil, showsAds: false, monthlyPoints: 5000)
        }
    }

    /// この画質で書き出せるいちばん下のプラン
    static func lowestTier(allowing resolution: ResolutionCap) -> PlanTier {
        PlanTier.allCases.first(where: { terms(for: $0).allows(resolution) }) ?? .pro
    }

    /// この長さ(秒)を書き出せるいちばん下のプラン
    static func lowestTier(allowingDuration duration: Double) -> PlanTier {
        PlanTier.allCases.first(where: { tier in
            guard let minutes = terms(for: tier).maxMinutes else { return true }
            return duration <= Double(minutes * 60) + 0.5
        }) ?? .pro
    }

    /// この画質で書き出せるか
    func allows(_ resolution: ResolutionCap) -> Bool {
        resolution.maxShortSide <= maxResolution.maxShortSide
    }
}

/// 有料プランの機能(raw value はプラン設定のページの機能 ID。tiers/current の features で free 以外のもの)。
/// 書き出しの画質・長さと広告は PlanTerms で決める。クラウド AI(文字起こし・字幕の整え・翻訳・AI台本・クラウドの声・吹き替え)は
/// プランで止めず、どのプランでもポイントで使う
enum PlanFeature: String, CaseIterable, Identifiable {
    case fillerCut = "ai.fillerCut"
    case editCheck = "ai.editCheck"
    case endScreen = "ai.endScreen"
    case audioEffects = "audio.effects"
    case loudness = "audio.loudness"
    case aiQuality = "color.aiQuality"
    case lookCopyPaste = "color.copyPaste"
    case lut = "color.lut"
    case teleprompter = "import.teleprompter"
    case backgroundRemoval = "motion.bgRemoval"
    case chromaKey = "motion.chromaKey"
    case mosaic = "motion.mosaic"
    case subjectFlash = "motion.subjectFlash"
    case multicam = "edit.multicam"

    var id: String { rawValue }

    /// 使えるいちばん下のプラン
    var requiredTier: PlanTier { self == .multicam ? .pro : .standard }

    /// 無料プランで 1 回だけ使うときのポイント(サーバーの POINTS.featureTrial と同じ)
    static let trialPoints = 50

    /// 無料プランでもポイントで 1 回使えるか(1 回で終わる機能。サーバーの FEATURE_TRIALS と同じ)
    var allowsTrial: Bool {
        switch self {
        case .fillerCut, .editCheck, .endScreen, .backgroundRemoval, .aiQuality: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .fillerCut: return String(localized: "言いよどみカット")
        case .editCheck: return String(localized: "編集チェック")
        case .endScreen: return String(localized: "終了画面")
        case .audioEffects: return String(localized: "音声効果")
        case .loudness: return String(localized: "音量そろえ")
        case .aiQuality: return String(localized: "画質補正")
        case .lookCopyPaste: return String(localized: "カラーのコピー・貼り付け")
        case .lut: return "LUT"
        case .teleprompter: return String(localized: "テレプロンプター")
        case .backgroundRemoval: return String(localized: "背景を消す")
        case .chromaKey: return String(localized: "クロマキー")
        case .mosaic: return String(localized: "モザイク")
        case .subjectFlash: return String(localized: "被写体フラッシュ")
        case .multicam: return String(localized: "マルチカメラ")
        }
    }

    /// ツールバーの項目 ID → 機能(ContentView の EditorToolItem の id。グループの中も見る)
    static let toolbarItems: [String: PlanFeature] = [
        "ai-fillers": .fillerCut,
        "ai-editcheck": .editCheck,
        "ai-endscreen": .endScreen,
        "clip-audio-effects": .audioEffects,
        "narration-audio-effects": .audioEffects,
        "root-loudness": .loudness,
        "narration-loudness": .loudness,
        "clip-ai-quality": .aiQuality,
        "look-copy": .lookCopyPaste,
        "look-paste": .lookCopyPaste,
        "look-apply-all": .lookCopyPaste,
        "overlay-look-copy": .lookCopyPaste,
        "overlay-look-paste": .lookCopyPaste,
        "multi-look-paste": .lookCopyPaste,
        "clip-lut": .lut,
        "clip-bg-removal": .backgroundRemoval,
        "overlay-bg-removal": .backgroundRemoval,
        "clip-chroma-key": .chromaKey,
        "overlay-chroma-key": .chromaKey,
        "clip-subject-flash": .subjectFlash,
        "addMosaic": .mosaic,
        "face-mosaic": .mosaic,
        "clip-multicam": .multicam,
    ]
}

/// 書き出しをプランで止める理由
enum PlanExportBlock: Identifiable, Equatable {
    /// プランの最高画質を超えている(無料 720p・Standard 1080p・Pro 4K)
    case resolution(ResolutionCap)
    /// 長さの上限(分)を超えている
    case length(maxMinutes: Int)

    var id: String {
        switch self {
        case .resolution(let r): return "resolution-\(r.rawValue)"
        case .length(let m): return "length-\(m)"
        }
    }
}

@MainActor
@Observable
final class PlanStore {
    static let shared = PlanStore()

    static let standardProductID = "com.yuyaogawa6960.videomania.standard.monthly"
    static let proProductID = "com.yuyaogawa6960.videomania.pro.monthly"
    static let productIDs = [standardProductID, proProductID]

    /// 前回わかったプラン(起動直後、StoreKit に聞き終わる前の表示・広告の判断に使う)
    private static let cacheKey = "vm.planTier"

    /// いまのプラン
    private(set) var tier: PlanTier
    /// いまのプランの期限(自動更新なら次の更新日)
    private(set) var expiresAt: Date?
    /// 有効な購入がほかのアカウントに結びついていて、ポイントを受け取れなかった
    private(set) var ownedByOtherAccount = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    var terms: PlanTerms { .terms(for: tier) }
    var isPaid: Bool { tier != .free }

    /// この機能をいまのプランで使えるか
    func allows(_ feature: PlanFeature) -> Bool { tier >= feature.requiredTier }

    private init() {
        tier = PlanTier(rawValue: UserDefaults.standard.string(forKey: Self.cacheKey) ?? "") ?? .free
    }

    static func tier(forProductID id: String) -> PlanTier? {
        switch id {
        case standardProductID: return .standard
        case proProductID: return .pro
        default: return nil
        }
    }

    /// 起動時に 1 回。ほかの端末での購入・更新・返金(Transaction.updates)も受け取る
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// いま有効な購入からプランを決め、サインインしていればサーバーに送って毎月のポイントを受け取る
    func refresh() async {
        var best: PlanTier = .free
        var expiry: Date?
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  let plan = Self.tier(forProductID: transaction.productID) else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            signed.append(result.jwsRepresentation)
            if plan > best || (plan == best && expiry == nil) {
                best = plan
                expiry = transaction.expirationDate
            }
        }
        tier = best
        expiresAt = expiry
        UserDefaults.standard.set(best.rawValue, forKey: Self.cacheKey)
        if !signed.isEmpty {
            ownedByOtherAccount = await AccountService.shared.syncSubscriptions(signed) == .ownedByOtherAccount
        } else {
            ownedByOtherAccount = false
        }
    }

    /// 書き出してよいか(だめならその理由)
    /// 長さを先に見る(画質の確認で「(プランの最高画質)で書き出す」を選んだら、そのまま書き出せるように)
    func exportBlock(resolution: ResolutionCap, duration: Double) -> PlanExportBlock? {
        let current = self.terms
        if let maxMinutes = current.maxMinutes, duration > Double(maxMinutes * 60) + 0.5 {
            return .length(maxMinutes: maxMinutes)
        }
        if !current.allows(resolution) { return .resolution(resolution) }
        return nil
    }
}
