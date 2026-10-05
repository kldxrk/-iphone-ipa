import SwiftUI

/// 诊断面板。
///
/// 存在的理由：素材来自第三方（尤其是 KiriKiri 的 .xp3），出问题时"打不开"或"素材缺失"
/// 往往说不清原因。这里把事实一次性摊开：脚本来自哪里、封包挂载了多少文件、
/// 脚本里有哪些可疑行、脚本引用的素材缺哪些、哪些是 iOS 本身解不了的格式。
struct DiagnosticsSheet: View {
    let title: String
    let diagnostics: [VNDiagnostic]
    @Environment(\.dismiss) private var dismiss

    /// 用独立的结构而不是元组：`ForEach` 不能以元组元素做 key path。
    /// 名字避开 SwiftUI 已有的 `Group`，免得遮蔽后出现莫名其妙的类型错误。
    private struct LevelGroup: Identifiable {
        let id: String
        let level: VNDiagnostic.Level
        let items: [VNDiagnostic]
    }

    private var groups: [LevelGroup] {
        let order: [(level: VNDiagnostic.Level, name: String)] =
            [(.error, "错误"), (.warning, "警告"), (.info, "信息")]
        var result: [LevelGroup] = []
        for entry in order {
            let items = diagnostics.filter { $0.level == entry.level }
            if !items.isEmpty {
                result.append(LevelGroup(id: entry.name, level: entry.level, items: items))
            }
        }
        return result
    }

    private func tint(_ level: VNDiagnostic.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func levelName(_ level: VNDiagnostic.Level) -> String {
        switch level {
        case .error: return "错误"
        case .warning: return "警告"
        case .info: return "信息"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if diagnostics.isEmpty {
                        Text("没有需要报告的问题。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .glassSurface(cornerRadius: GlassMetrics.card)
                    }

                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(levelName(group.level), systemImage: group.level.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(tint(group.level))

                            ForEach(group.items) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.level.symbol)
                                        .font(.caption)
                                        .foregroundStyle(tint(item.level))
                                        .padding(.top, 2)
                                    Text(item.text)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(cornerRadius: GlassMetrics.card)
                    }

                    Text("提示：.ogg 音乐、.tlg 图片、.mpg/.wmv 视频是 KiriKiri 常用格式，iOS 系统本身没有解码器，需要先转码。受保护的加密封包无法解开——密钥不在文件格式里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
