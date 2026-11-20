import Foundation
import LocalAuthentication

/// 控车前的本人确认。Face ID 只是"取出已保存的操作密码"的钥匙，
/// 真正发给服务端的仍然是加密后的操作密码，生物识别不能替代它。
struct BiometricGate: Sendable {

    enum Kind {
        case faceID
        case touchID
        case opticID
        case none

        var label: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            case .none: return "生物识别"
            }
        }

        var symbol: String {
            switch self {
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .opticID: return "opticid"
            case .none: return "lock.shield"
            }
        }
    }

    static var available: Kind {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    /// 返回 true 表示验证通过；用户取消或识别失败都返回 false，由调用方回退到操作密码。
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "使用操作密码"
        context.localizedCancelTitle = "取消"
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
