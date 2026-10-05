import SwiftUI

/// 注意：这几个面板都**不**设置自己的背景，也不调用 `presentationBackground`。
/// iOS 26 的 sheet 默认自带玻璃背景，一旦覆盖就失去玻璃观感；旧系统则是标准的系统背景，
/// 里面的玻璃卡片照样成立。
struct LogSheet: View {
    @ObservedObject var runtime: VNRuntime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if runtime.log.isEmpty {
                            Text("还没有记录。")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .glassSurface(cornerRadius: GlassMetrics.bubble)
                        }
                        ForEach(runtime.log) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                if let who = entry.speaker {
                                    Text(who)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.text)
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassSurface(cornerRadius: GlassMetrics.bubble)
                            .id(entry.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    if let last = runtime.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

struct SlotSheet: View {
    enum Mode { case save, load }

    @ObservedObject var runtime: VNRuntime
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var slots: [Int: VNSave] = [:]

    private var range: [Int] {
        mode == .load ? Array(0...SaveManager.slotCount) : Array(1...SaveManager.slotCount)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(range, id: \.self) { n in
                        Button { pick(n) } label: { row(n) }
                            .buttonStyle(.plain)
                            .disabled(mode == .load && slots[n] == nil)
                    }
                }
                .padding(16)
            }
            .navigationTitle(mode == .save ? "存档" : "读档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .onAppear { slots = runtime.slotSummaries() }
        }
    }

    private func pick(_ n: Int) {
        if mode == .save { runtime.save(slot: n) } else { runtime.load(slot: n) }
        dismiss()
    }

    private func row(_ n: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: n == 0 ? "clock.arrow.circlepath" : "square.and.pencil")
                .font(.body)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(n == 0 ? "自动存档" : "栏位 \(n)").font(.headline)
                if let s = slots[n] {
                    Text(s.preview).lineLimit(1).font(.subheadline)
                    Text(s.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("空").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: GlassMetrics.bubble, interactive: true)
        .opacity(mode == .load && slots[n] == nil ? 0.45 : 1)
    }
}

struct SettingsSheet: View {
    @ObservedObject var runtime: VNRuntime
    @Environment(\.dismiss) private var dismiss
    @AppStorage("textSpeed") private var textSpeed: Double = 40
    @AppStorage("bgmVolume") private var bgmVolume: Double = 0.7

    /// 统一返回 Color：三元表达式里混用 `.secondary`（HierarchicalShapeStyle）与 `.red`（Color）无法通过类型检查。
    static func tint(for level: VNDiagnostic.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("文字速度").font(.subheadline.weight(.semibold))
                        Slider(value: $textSpeed, in: 10...100, step: 5)
                        Text(textSpeed >= 100 ? "瞬间显示" : "\(Int(textSpeed)) 字/秒")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(cornerRadius: GlassMetrics.card)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("音乐音量").font(.subheadline.weight(.semibold))
                        Slider(value: $bgmVolume, in: 0...1)
                        Text("\(Int(bgmVolume * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(cornerRadius: GlassMetrics.card)

                    if !runtime.diagnostics.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("本次载入的诊断").font(.subheadline.weight(.semibold))
                            ForEach(runtime.diagnostics.prefix(12)) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.level.symbol)
                                        .font(.caption)
                                        .foregroundStyle(SettingsSheet.tint(for: item.level))
                                    Text(item.text).font(.footnote)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if runtime.diagnostics.count > 12 {
                                Text("……完整列表请看游戏库里的体检报告")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(cornerRadius: GlassMetrics.card)
                    }
                }
                .padding(16)
            }
            .onChange(of: bgmVolume) { v in runtime.setBGMVolume(Float(v)) }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
