import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = GameLibrary()
    @StateObject private var runtime = VNRuntime()
    @State private var activeGame: VNGameInfo?
    @State private var showImporter = false
    @State private var inspection: Inspection?

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
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(library.unsupported, id: \.self) { reason in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                            .padding(.top, 1)
                                        Text(reason)
                                            .font(.footnote)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(16)
                            .glassSurface(cornerRadius: GlassMetrics.card)
                        }

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
                Text(game.sourceLabel).font(.caption).foregroundStyle(.secondary)
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
                Button(role: .destructive) { library.delete(game) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func start(_ game: VNGameInfo) {
        if runtime.open(game) { activeGame = game }
    }
}
