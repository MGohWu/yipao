import SwiftUI

/// 内置法律文档：用户协议、隐私政策。
///
/// 文档源文件是 `LeapControl/Legal/*.md`，打包进 App 随包发，点开即看，
/// 不依赖网络，离线也能打开。
enum LegalDoc: String, Identifiable {
    case userAgreement = "user-agreement"
    case privacy = "privacy-policy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userAgreement: return "用户协议"
        case .privacy: return "隐私政策"
        }
    }

    /// 从 App bundle 读 markdown 原文。读不到时给一句兜底，不至于弹个空白页。
    var markdown: String {
        guard
            let url = Bundle.main.url(forResource: rawValue, withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "文档暂时无法加载，请在本项目的开源代码仓库提交 Issue。"
        }
        return text
    }
}

/// 一个极简 markdown 渲染：够呈现这两份文档就行，不追求通用。
/// 支持 `#`/`##` 标题、`-` 列表、`| a | b |` 表格行、以及行内 `**加粗**`。
struct LegalDocView: View {
    let doc: LegalDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        block.view
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(doc.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var blocks: [Block] {
        doc.markdown
            .components(separatedBy: "\n")
            .map(Block.init)
    }

    /// 一行 markdown 对应一个块。表格分隔行（`|---|`）直接吃掉。
    private struct Block {
        enum Kind { case title, heading, bullet, table, body, blank }
        let kind: Kind
        let raw: String

        init(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { kind = .blank; raw = ""; return }
            if trimmed.hasPrefix("## ") { kind = .heading; raw = String(trimmed.dropFirst(3)); return }
            if trimmed.hasPrefix("# ") { kind = .title; raw = String(trimmed.dropFirst(2)); return }
            if trimmed.hasPrefix("- ") { kind = .bullet; raw = String(trimmed.dropFirst(2)); return }
            if trimmed.hasPrefix("|") {
                // 分隔行不显示，只留有内容的表格行。
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { kind = .blank; raw = ""; return }
                kind = .table
                raw = cells.joined(separator: "  ·  ")
                return
            }
            kind = .body; raw = trimmed
        }

        /// 行内 `**加粗**` 交给系统的 markdown 解析，其余按块类型定字体。
        private var inline: AttributedString {
            (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
        }

        @ViewBuilder var view: some View {
            switch kind {
            case .blank:
                Color.clear.frame(height: 2)
            case .title:
                Text(inline).font(.title2.weight(.semibold)).padding(.bottom, 2)
            case .heading:
                Text(inline).font(.headline).padding(.top, 8)
            case .bullet:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(inline).font(.subheadline)
                }
            case .table:
                Text(inline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            case .body:
                Text(inline).font(.subheadline)
            }
        }
    }
}
