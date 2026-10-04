import SwiftUI

struct ContentView: View {
    @StateObject private var runtime = VNRuntime()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "gamecontroller").font(.system(size: 60))
                Text("Visual Novel Player").font(.largeTitle.bold())
                Text("iOS 视觉小说运行时原型").foregroundStyle(.secondary)

                Button("启动 Demo") { runtime.loadDemo() }
                    .buttonStyle(.borderedProminent)

                if runtime.game != nil {
                    NavigationLink("进入游戏") {
                        PlayerView(runtime: runtime)
                            .navigationBarBackButtonHidden()
                    }
                }

                Text("不执行 Windows EXE/DLL；通过运行时和资源接口接入具体引擎。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .padding()
            .navigationTitle("游戏库")
        }
    }
}
