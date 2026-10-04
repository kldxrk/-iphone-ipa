# 下一步

1. 把整个目录上传到 Gitee。
2. Codemagic 连接这个仓库。
3. 在 Codemagic 的 Apple Developer / App Store Connect Integration 中完成 Apple 账号授权。
4. 将 `PRODUCT_BUNDLE_IDENTIFIER` / `bundle_identifier` 从 `com.example.vnplayer` 改成你自己的唯一 ID。
5. 运行 `ios-release`。
6. 成功后，Artifacts 中会出现 `.ipa`；若 App Store Connect 权限正确，也会提交 TestFlight。

重要：Apple 签名必须由你的 Apple Developer 账号完成。不要把证书、私钥或 API key 发给我。
