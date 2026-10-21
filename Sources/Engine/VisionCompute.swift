import Foundation
import Vision
import CoreML

// =====================================================================
// Vision の計算先: アプリが裏にあり、裏で GPU を使う許可が無いときは CPU だけで動かす
// (許可なく裏で GPU を使うと、iOS にアプリを終了させられることがある)
// =====================================================================

enum VisionCompute {
    static func prepare(_ requests: [VNRequest]) {
        let lifecycle = AppLifecycle.shared
        guard lifecycle.isInBackground && !lifecycle.backgroundGPUAllowed else { return }
        for request in requests {
            guard let devices = try? request.supportedComputeStageDevices else { continue }
            for (stage, list) in devices {
                if let cpu = list.first(where: { device in
                    if case .cpu = device { return true }
                    return false
                }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
    }
}
