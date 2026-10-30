// =====================================================================
// カメラの Wi-Fi(アクセスポイント)に iPhone をつなぐ(実験中・開発者向け)
//
// 手順は OpenPocketCine の資料(handbook/protocol/wifi.md、Apache 2.0)と
// OpenCine の DjiAppleWiFiJoiner.swift を参考に、この app 用に短く書き直したもの。
//
// - Wi-Fi 名とパスワードは BLE で読む(GetWifiSsid / GetWifiPassword)。パスワードは作らない
// - NEHotspotConfiguration には Hotspot Configuration の権限(entitlement)が要る
// - apply が成功しても「つながった」とは限らない(パスワード違いでも成功が返る)。
//   192.168.2.x のアドレスが付くまで待つ。カメラは 192.168.2.1
// - 5.8GHz の地域ではカメラの電波が出るまで約 1 分かかることがある。90 秒までやり直す
// - 実機ではまだ一度も試していない
// =====================================================================

#if OSMO_LIVE
import Darwin
import Foundation
import NetworkExtension

@MainActor
enum OsmoWiFi {
    nonisolated static let cameraHost = "192.168.2.1"

    /// カメラの Wi-Fi に入る。192.168.2.x が付いたら戻る
    static func join(ssid: String, passphrase: String, log: (String) -> Void) async throws {
        if let ip = cameraLocalIPv4() {
            log("wifi: already have \(ip), skip apply")
            return
        }
        let deadline = Date().addingTimeInterval(90)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
            // アプリが前面にあるあいだだけつなぐ(後ろに回ると iOS が元の Wi-Fi に戻す)
            config.joinOnce = true
            do {
                try await NEHotspotConfigurationManager.shared.apply(config)
                log("wifi: apply ok #\(attempt)")
            } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
                switch NEHotspotConfigurationError(rawValue: error.code) {
                case .alreadyAssociated:
                    log("wifi: already associated")
                case .userDenied:
                    throw OsmoError.wifi("「接続」が許可されませんでした")
                default:
                    log("wifi: apply error \(error.code) \(error.localizedDescription)")
                }
            }
            if try await waitForCameraAddress(timeout: min(15, max(1, deadline.timeIntervalSinceNow))) {
                return
            }
            guard deadline.timeIntervalSinceNow > 10 else {
                throw OsmoError.wifi("192.168.2.x が付きませんでした。パスワード違い、または 5.8GHz で電波がまだ出ていない可能性があります")
            }
            log("wifi: no 192.168.2.x yet, retry (\(Int(deadline.timeIntervalSinceNow)) s left)")
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            try await Task.sleep(for: .seconds(3))
        }
    }

    static func leave(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    private static func waitForCameraAddress(timeout: TimeInterval) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            try Task.checkCancellation()
            if cameraLocalIPv4() != nil { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// カメラから DHCP でもらった iPhone の IPv4(192.168.2.2〜254)。無ければ nil
    nonisolated static func cameraLocalIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4, parts[0] == 192, parts[1] == 168, parts[2] == 2, (2...254).contains(parts[3]) {
                return ip
            }
        }
        return nil
    }
}
#endif
