import Foundation
import Testing
@testable import LeapControl

/// 「锁屏久了解锁，第一下必报网络连接已中断」的两块修复：瞬时错误重试的判据表，
/// 和把 `URLError` 翻成用户话的映射。
///
/// 成因见 `LeapClient.send(_:retriesOnTimeout:)` 的注释：锁屏期间 iOS 挂起网络接口，
/// `URLSession` 连接池里的 keep-alive 连接已经死了但池子不知道，解锁后复用它发第一个包
/// 就拿到 -1005。真实的连接池行为在单测里没法复现，所以这里只钉零件——哪些错误码该重发、
/// 哪些翻成什么话——装配顺序靠代码评审。
@Suite("网络瞬时错误的自愈零件")
struct NetworkResilienceTests {

    // MARK: - 重试判据

    /// 连接层就失败的那几种：包没能交给服务端，所以控车这类非幂等 POST 重发也安全。
    @Test("连接层失败一律重发，不分请求是否幂等", arguments: [
        URLError.Code.networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .secureConnectionFailed,
    ])
    func connectionLevelFailuresRetry(code: URLError.Code) {
        let error = URLError(code)
        #expect(LeapClient.isRetriableTransportFailure(error, retriesOnTimeout: true))
        #expect(
            LeapClient.isRetriableTransportFailure(error, retriesOnTimeout: false),
            "非幂等请求也要重发：这几种错误的包根本没到服务端，不存在重复下发"
        )
    }

    /// 超时是唯一按幂等性分流的：请求可能已经到服务端了，只是回包慢。
    @Test("超时只有幂等请求才重发")
    func timeoutRetriesOnlyWhenIdempotent() {
        let error = URLError(.timedOut)
        #expect(LeapClient.isRetriableTransportFailure(error, retriesOnTimeout: true))
        #expect(
            !LeapClient.isRetriableTransportFailure(error, retriesOnTimeout: false),
            "控车 POST 超时后重发，可能变成对车下发两次同一条指令"
        )
    }

    /// 重发过不去、或者重发本身有害的，一条都不能收进判据表。
    @Test("证书类和取消一概不重发", arguments: [
        URLError.Code.serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot,
        .cancelled,
        .badURL,
        .unsupportedURL,
    ])
    func nonRetriableCodesAreNotRetried(code: URLError.Code) {
        #expect(!LeapClient.isRetriableTransportFailure(URLError(code), retriesOnTimeout: true))
    }

    @Test("不是 URLError 的错误不进重试通道")
    func nonURLErrorsAreNotRetried() {
        #expect(!LeapClient.isRetriableTransportFailure(LeapError.sessionExpired, retriesOnTimeout: true))
        #expect(!LeapClient.isRetriableTransportFailure(CancellationError(), retriesOnTimeout: true))
    }

    // MARK: - 文案映射

    /// 翻译的意义就在这儿：不翻的话弹给用户的是系统原文「网络连接已中断」，
    /// 而用户的网络好好的，坏的是 App 手里那条死连接。
    @Test("URLError 翻成用户话，不再泄露系统原文", arguments: [
        URLError.Code.networkConnectionLost,
        .notConnectedToInternet,
        .timedOut,
        .cannotConnectToHost,
        .secureConnectionFailed,
    ])
    func urlErrorsAreTranslated(code: URLError.Code) throws {
        let wrapped = LeapError.wrapping(URLError(code))
        let leapError = try #require(wrapped as? LeapError)
        guard case .network(let message) = leapError else {
            Issue.record("URLError 应该翻成 .network，实际是 \(leapError)")
            return
        }
        #expect(!message.isEmpty)
        #expect(
            message != URLError(code).localizedDescription,
            "翻完还是系统原话就等于没翻"
        )
    }

    /// 切车、退到后台停轮询都会取消在途请求，翻了就成了平白弹一条网络错误。
    @Test("取消不翻译")
    func cancellationIsNotTranslated() {
        let cancelled = URLError(.cancelled)
        let wrapped = LeapError.wrapping(cancelled)
        #expect((wrapped as? URLError)?.code == .cancelled)
    }

    /// 断网只是这次请求没成。翻成 `sessionExpired` 就会把人踢回登录页——
    /// 这正是 `LeapClient` 那张 `reauthPhrases` 表反复收窄要避开的事故。
    @Test("网络错误绝不能被翻成登录失效")
    func networkErrorsNeverBecomeSessionExpiry() {
        for code: URLError.Code in [.networkConnectionLost, .notConnectedToInternet, .timedOut, .userAuthenticationRequired] {
            if case LeapError.sessionExpired = LeapError.wrapping(URLError(code)) {
                Issue.record("URLError \(code.rawValue) 被翻成了登录失效")
            }
        }
    }

    @Test("非 URLError 原样放行，不被包成网络错误")
    func nonURLErrorsPassThrough() {
        let original = LeapError.server("该车辆未授权")
        guard case LeapError.server(let message) = LeapError.wrapping(original) else {
            Issue.record("业务错误被 wrapping 改写了")
            return
        }
        #expect(message == "该车辆未授权")
    }
}

/// 老链路表单/query 的转义。
///
/// 钉的是 2026-08-22 那次事故：`oppwd` 是 AES 密文的 Base64，而原来用
/// `URLComponents.queryItems` 拼请求体——它的允许字符集放行 `+`，
/// 可 `application/x-www-form-urlencoded` 规定 `+` 解码成空格。
/// 于是服务端拿到的 `oppwd` 和客户端**签名时用的**不是同一串，它重算 `signStr`
/// 必然对不上，回 `result=39 信息校验失败`。而密钥由 token 派生、加密确定性，
/// 同一个 token 周期内密文固定：一旦这串密文里有 `+`，这 6 小时内每条控制指令
/// 都失败，重试多少次都不会好——真机实测密文正是 24 字符且含 `+`。
@Suite("老链路参数转义")
struct StrictFormEncodingTests {

    /// 事故本体：Base64 的三个特殊字符一个都不能漏。
    @Test("Base64 密文里的 + / = 全部转义")
    func base64SpecialCharactersEscaped() {
        let encoded = LeapClient.strictFormEncoded(["oppwd": "ab+cd/ef=="])
        #expect(encoded == "oppwd=ab%2Bcd%2Fef%3D%3D")
        #expect(!encoded.contains("+"), "留下裸 + 就会被服务端解成空格，签名必然对不上")
    }

    /// 反过来也要钉住：老实的值不能被改写，否则等于换了一套签名口径。
    @Test("十六进制、VIN、时间戳这些值编码前后完全一致", arguments: [
        "2A6F88CEB04E4300AAA649D56589E623",
        "LC0C24E40M0000001",
        "1787413142684",
        "d41d8cd98f00b204",
    ])
    func plainValuesUnchanged(value: String) {
        #expect(LeapClient.strictFormEncoded(["v": value]) == "v=\(value)")
    }

    /// 控车的 `state` 是 JSON 字符串，花括号和引号必须编码，否则服务端拆不出参数。
    @Test("state 的 JSON 结构字符被转义")
    func jsonStateEscaped() {
        let encoded = LeapClient.strictFormEncoded(["state": #"{"value":"true"}"#])
        #expect(encoded == "state=%7B%22value%22%3A%22true%22%7D")
    }

    /// 空格在 form 里既可以写 `+` 也可以写 `%20`，但我们只用 `%20`——
    /// 签名拼的是原始值，两种写法服务端解出来虽都是空格，混用只会再埋一次同样的雷。
    @Test("空格编码成 %20 而不是 +")
    func spaceEncodedAsPercent20() {
        #expect(LeapClient.strictFormEncoded(["k": "a b"]) == "k=a%20b")
    }

    @Test("多个参数按键名排序拼接，同样输入永远同样输出")
    func stableOrdering() {
        let params = ["carvin": "LC0", "cmdid": "120", "nonce": "abc"]
        #expect(LeapClient.strictFormEncoded(params) == "carvin=LC0&cmdid=120&nonce=abc")
    }
}
