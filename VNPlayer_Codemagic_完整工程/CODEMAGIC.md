# Codemagic 构建说明

1. 将整个项目放入 Git 仓库。
2. 在 Codemagic 添加仓库。
3. 在 Apple Developer / App Store Connect 创建或选择 App ID：
   `com.example.vnplayer`
4. 在 Codemagic 的 Code signing / Integrations 中连接 Apple Developer。
5. 把 Bundle ID 改成你自己的唯一 ID。
6. 运行 `ios-release` workflow。
7. 云端 macOS 会负责 iOS archive 和签名构建。

注意：当前 ZIP 是 SwiftUI 源码框架，还需要在 Xcode 项目中把 Sources 和 Resources 纳入 target。
本配置提供 Codemagic 的构建方向，并不绕过 Apple Developer 签名要求。
