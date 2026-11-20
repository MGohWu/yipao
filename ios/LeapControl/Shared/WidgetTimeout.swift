import Foundation

/// 给一段异步工作压上超时；超时就返回兜底值。
///
/// 卡片的时间线和锁屏控件的取值都有系统给的时间预算，超了不是"慢一点"，
/// 是扩展进程被直接干掉、界面停在上一次渲染的画面上。所以凡是要联网的地方
/// 都得自己压一道，绝不把"交不出结果"这种可能留给系统处理。
enum WidgetTimeout {
    static func within<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }
}
