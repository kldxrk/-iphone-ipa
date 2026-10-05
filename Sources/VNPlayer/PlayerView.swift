import SwiftUI

enum PlayerSheet: String, Identifiable {
    case log, save, load, settings
    var id: String { rawValue }
}

struct PlayerView: View {
    @ObservedObject var runtime: VNRuntime
    @Environment(\.dismiss) private var dismiss
    @AppStorage("textSpeed") private var textSpeed: Double = 40

    @State private var progress: Double = 0
    @State private var completedAt: Date? = nil
    @State private var sheet: PlayerSheet? = nil

    /// 必须是 static：View 结构体在每次状态变化时都会重新构造，
    /// 写成实例属性会让计时器订阅被反复重建，打字机/自动/快进都会卡顿。
    private static let ticker = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    private var total: Int { runtime.fullText.count }
    private var textComplete: Bool { progress >= Double(total) }
    private var visibleText: String { String(runtime.fullText.prefix(Int(progress))) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            sceneLayer.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Spacer(minLength: 0)
                if runtime.isFinished {
                    finishedCard
                } else {
                    if !runtime.choices.isEmpty && textComplete { choiceList }
                    dialogueBox
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            if let m = runtime.message {
                VStack {
                    Spacer()
                    Text(m)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassSurface(cornerRadius: GlassMetrics.bubble, prominent: true)
                        .padding(.bottom, 150)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .onReceive(PlayerView.ticker) { now in tick(now) }
        .onChange(of: runtime.lineID) { _ in
            progress = 0
            completedAt = nil
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .log: LogSheet(runtime: runtime)
            case .save: SlotSheet(runtime: runtime, mode: .save)
            case .load: SlotSheet(runtime: runtime, mode: .load)
            case .settings: SettingsSheet(runtime: runtime)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: - 画面层

    private var sceneLayer: some View {
        GeometryReader { geo in
            ZStack {
                backgroundView(size: geo.size)
                ForEach(runtime.sprites) { sp in
                    if let img = runtime.assets?.image(sp.file) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: geo.size.height * 0.88)
                            .position(x: spriteX(sp.pos, width: geo.size.width),
                                      y: geo.size.height - geo.size.height * 0.44)
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: runtime.sprites)
        }
    }

    @ViewBuilder
    private func backgroundView(size: CGSize) -> some View {
        if let name = runtime.background, let img = runtime.assets?.image(name) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            GlassBackdrop()
        }
    }

    private func spriteX(_ pos: String, width: CGFloat) -> CGFloat {
        switch pos.lowercased() {
        case "left": return width * 0.22
        case "right": return width * 0.78
        default: return width * 0.5
        }
    }

    // MARK: - 界面

    private var topBar: some View {
        // 放在同一个 GlassEffectContainer 里，iOS 26 上相邻按钮的玻璃会互相融合
        GlassGroup(spacing: 12) {
            HStack(spacing: 8) {
                barButton("退出", on: false) { dismiss() }
                Spacer(minLength: 8)
                barButton("自动", on: runtime.autoMode) {
                    runtime.autoMode.toggle()
                    if runtime.autoMode { runtime.skipMode = false }
                }
                barButton("快进", on: runtime.skipMode) {
                    runtime.skipMode.toggle()
                    if runtime.skipMode { runtime.autoMode = false }
                }
                barButton("记录", on: false) { sheet = .log }
                barButton("存档", on: false) { sheet = .save }
                barButton("读档", on: false) { sheet = .load }
                barButton("设置", on: false) { sheet = .settings }
            }
        }
    }

    private func barButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .glassButton(prominent: on)
    }

    private var choiceList: some View {
        VStack(spacing: 10) {
            ForEach(runtime.choices) { c in
                Button { runtime.choose(c) } label: {
                    Text(c.text)
                        .font(.system(size: 18, weight: .medium))
                        .frame(maxWidth: 460)
                        .multilineTextAlignment(.center)
                }
                .glassButton()
            }
        }
        .padding(.bottom, 4)
    }

    private var dialogueBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = runtime.speaker {
                Text(name)
                    .font(.system(size: 17, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .glassSurface(cornerRadius: GlassMetrics.bubble, tint: .accentColor, prominent: true)
            }
            Text(visibleText)
                .font(.system(size: 19))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: GlassMetrics.card)
        .glassRimLight(cornerRadius: GlassMetrics.card)
    }

    private var finishedCard: some View {
        VStack(spacing: 14) {
            Text("— 完 —").font(.system(size: 26, weight: .bold))
            HStack(spacing: 12) {
                Button("重新开始") { runtime.restart() }
                    .glassButton()
                Button("返回游戏库") { dismiss() }
                    .glassButton(prominent: true)
            }
        }
        .padding(22)
        .glassSurface(cornerRadius: GlassMetrics.card)
    }

    // MARK: - 交互

    private var overlayActive: Bool { sheet != nil }

    private func handleTap() {
        guard !overlayActive else { return }
        if runtime.skipMode { runtime.skipMode = false }
        if runtime.isFinished || !runtime.choices.isEmpty { return }
        if progress < Double(total) {
            progress = Double(total)
            completedAt = Date()
        } else {
            runtime.next()
        }
    }

    private func tick(_ now: Date) {
        if overlayActive || runtime.isFinished { return }
        let count = Double(total)
        if progress < count {
            if runtime.skipMode || textSpeed >= 100 {
                progress = count
            } else {
                progress += textSpeed * 0.03
            }
            if progress >= count { completedAt = now }
            return
        }
        guard runtime.choices.isEmpty else { return }
        if completedAt == nil { completedAt = now }
        let wait: TimeInterval
        if runtime.skipMode {
            wait = 0.08
        } else if runtime.autoMode {
            wait = 1.2 + count * 0.06
        } else {
            return
        }
        if let c = completedAt, now.timeIntervalSince(c) >= wait {
            completedAt = nil
            runtime.next()
        }
    }
}
