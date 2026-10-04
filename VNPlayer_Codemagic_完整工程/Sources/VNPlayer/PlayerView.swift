import SwiftUI

struct PlayerView: View {
    @ObservedObject var runtime: VNRuntime

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.black).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                if let scene = runtime.currentScene {
                    Text(scene.background ?? "BACKGROUND")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        if let speaker = scene.speaker { Text(speaker).font(.headline) }
                        Text(scene.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding()
                }
                HStack {
                    Button("上一句") { runtime.previous() }
                    Spacer()
                    Button("存档") { runtime.save(slot: 1) }
                    Button("读档") { runtime.load(slot: 1) }
                    Spacer()
                    Button("下一句") { runtime.next() }
                }
                .padding()
                .buttonStyle(.borderedProminent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { runtime.next() }
    }
}
