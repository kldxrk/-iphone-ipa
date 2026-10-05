import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = GameLibrary()
    @StateObject private var runtime = VNRuntime()
    @State private var activeGame: VNGameInfo?
    @State private var showImporter = false
    @State private var inspection: Inspection?
    @State private var deleteTarget: DeleteTarget?

    /// 删除操作统一走确认对话框：以前导入进来又认不出来的东西根本没有入口能删掉。
    private enum DeleteTarget: Identifiable {
        case game(VNGameInfo)
        case unsupported(GameLibrary.UnsupportedGame)
        case allImported

        var id: String {
            switch self {
            case .game(let game): return "game-" + game.id
            case .unsupported(let item): return "unsupported-" + item.folder.path
            case .allImported: return "all-imported"
            }
        }

        var title: String {
            switch self {
            case .game(let game): return game.title
            case .unsupported(let item): return item.name
            case .allImported: return "全部导入的数据"
            }
        }
    }

    private struct Inspection: Identifiable {
        let id = UUID()
        let title: String
        let items: [VNDiagnostic]
    }

    private let helpText = """
    添加游戏：在「文件」App 里把游戏文件夹复制到 我的 iPhone → VNPlayer → Games，然后点右上角刷新；\
    也可以点导入按钮选择文件夹。

    每个游戏文件夹里要有 script.vns（散装素材），或者一个 KiriKiri 的 .xp3 封包 —— \
    两种都能直接玩。点卡片右下角的听诊器图标可以先体检：看脚本能不能解析、素材缺哪些、\
    哪些格式 iOS 本身解不了。

    注意：VNPlayer 不运行 Windows 的 EXE / DLL，也不执行 TJS2 脚本；加密封包无法解开。
    """

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackdrop().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if library.games.isEmpty {
                            Text("还没有游戏")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .glassSurface(cornerRadius: GlassMetrics.card)
                        } else {
                            sectionTitle("游戏")
                            ForEach(library.games) { game in
                                gameCard(game)
                            }
                        }

                        if !library.unsupported.isEmpty {
                            sectionTitle("无法识别")
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(library.unsupported) { item in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name).font(.subheadline.weight(.semibold))
                                            Text(item.reason)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        // 真实 KR 游戏大多落在这里：先让用户拿到"要哪条路线"的结论
                                        Button {
                                            let report = CompatibilityAnalyzer.analyze(
                                                folder: item.folder,
                                                archiveURL: GameStore.archiveCandidate(in: item.folder))
                                            inspection = Inspection(title: "兼容性报告：\(item.name)",
                                                                    items: report.diagnostics)
                                        } label: {
                                            Label("体检", systemImage: "stethoscope")
                                                .font(.footnote)
                                                .labelStyle(.titleAndIcon)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            deleteTarget = .unsupported(item)
                                        } label: {
                                            Image(systemName: "trash").font(.footnote)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.red)
                                    }
                                }
                            }
                            .padding(16)
                            .glassSurface(cornerRadius: GlassMetrics.card)
                        }

                        sectionTitle("存储管理")
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("导入的数据（ImportedGames）", systemImage: "square.and.arrow.down")
                                Spacer()
                                Text(CompatibilityReport.sizeText(library.importedBytes))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)

                            HStack {
                                Label("自己放进来的（Games）", systemImage: "folder")
                                Spacer()
                                Text(CompatibilityReport.sizeText(library.gamesBytes))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)

                            Button(role: .destructive) {
                                deleteTarget = .allImported
                            } label: {
                                Label("清空导入的数据", systemImage: "trash")
                                    .font(.footnote)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(library.importedBytes == 0)

                            Text("导入的游戏存在 ImportedGames 目录，和你用「文件」App 放进 Games 的分开；长按卡片或点垃圾桶都能删除单个游戏。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(cornerRadius: GlassMetrics.card)

                        sectionTitle("如何添加游戏")
                        Text(helpText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .glassSurface(cornerRadius: GlassMetrics.card)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("游戏库")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: {
                        Label("导入文件夹", systemImage: "square.and.arrow.down")
                    }
                    Button { library.refresh() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let m = library.message ?? runtime.message {
                    Text(m)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassSurface(cornerRadius: GlassMetrics.bubble, prominent: true)
                        .padding(.bottom, 16)
                }
            }
            .overlay {
                if library.isImporting {
                    ProgressView("导入中…")
                        .padding(22)
                        .glassSurface(cornerRadius: GlassMetrics.card)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let u = urls.first { library.importFolder(u) }
            case .failure(let error):
                library.report("导入失败：\(error.localizedDescription)")
            }
        }
        .fullScreenCover(item: $activeGame, onDismiss: { runtime.close() }) { _ in
            PlayerView(runtime: runtime)
        }
        .sheet(item: $inspection) { item in
            DiagnosticsSheet(title: item.title, diagnostics: item.items)
        }
        .confirmationDialog("确认删除「\(deleteTarget?.title ?? "")」？",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: deleteTarget) { target in
            Button("删除", role: .destructive) { performDelete(target) }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text(deleteMessage(target))
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func gameCard(_ game: VNGameInfo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: game.isBuiltIn ? "star.fill" : (game.archive != nil ? "shippingbox.fill" : "book.closed"))
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline)
                HStack(spacing: 6) {
                    Text(game.sourceLabel).font(.caption).foregroundStyle(.secondary)
                    if game.isImported {
                        Text("导入")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                inspection = Inspection(title: game.title, items: runtime.inspect(game))
            } label: {
                Image(systemName: "stethoscope")
                    .font(.body)
                    .padding(6)
            }
            .buttonStyle(.plain)

            Image(systemName: "play.fill").foregroundStyle(.tint)
        }
        .padding(16)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: GlassMetrics.card, interactive: true)
        .onTapGesture { start(game) }
        .contextMenu {
            if !game.isBuiltIn {
                Button(role: .destructive) { deleteTarget = .game(game) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func performDelete(_ target: DeleteTarget) {
        switch target {
        case .game(let game): library.delete(game)
        case .unsupported(let item): library.delete(item)
        case .allImported: library.clearImported()
        }
        deleteTarget = nil
    }

    private func deleteMessage(_ target: DeleteTarget) -> String {
        switch target {
        case .game, .unsupported:
            return "会同时删掉素材与这个游戏的存档，无法恢复。"
        case .allImported:
            return "会删掉所有通过「导入」拷进来的游戏及其存档；你自己用「文件」App 放进 Games 的不会被删。"
        }
    }

    private func start(_ game: VNGameInfo) {
        if runtime.open(game) { activeGame = game }
    }
}
