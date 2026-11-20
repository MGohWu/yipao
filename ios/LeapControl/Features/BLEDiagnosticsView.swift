import SwiftUI

struct BLEDiagnosticsView: View {
    @State private var file: URL?
    @State private var message = ""

    var body: some View {
        List {
            Section {
                Text("重现连接失败后，点刷新，再分享日志。日志包含扫描、连接、认证阶段和车辆错误码，不包含证书、密钥或登录凭证。")
                Button("刷新日志", systemImage: "arrow.clockwise", action: refresh)
                if let file {
                    ShareLink(item: file) { Label("分享蓝牙日志", systemImage: "square.and.arrow.up") }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("蓝牙诊断")
        .task { refresh() }
    }

    private func refresh() {
        do {
            file = try BLEDiagnostics.export()
            message = "已更新：\(Date.now.formatted(date: .omitted, time: .standard))"
        } catch {
            file = nil
            message = "日志导出失败，请重试"
        }
    }
}
