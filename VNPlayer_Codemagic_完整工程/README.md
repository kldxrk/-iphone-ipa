# VNPlayer iOS Framework

一个非特定、非成人视觉小说 iOS 运行时原型。

## 架构
SwiftUI UI
 -> VNRuntime
 -> ScriptEngine / ResourceProvider / SaveManager / InputMapper
 -> ArchiveProvider（Directory / PAC / XP3 可插拔）

当前原型不执行 Windows EXE/DLL。这样可以在 iOS 上把“游戏引擎兼容”与“Windows 系统模拟”分开。

## 使用
在 Mac 上用 Xcode 新建 iOS SwiftUI App，把 Sources/VNPlayer 中的 Swift 文件加入工程，
并把 Resources/demo.json 加入 Copy Bundle Resources。选择 iOS Simulator 或真机编译。

真正 IPA 还需要 macOS + Xcode + Apple 签名环境。
