# 构建说明（无 Mac）

工程是完整的 Xcode 工程（VNPlayer.xcodeproj + 共享 scheme）。

## 关于 Xcode 版本与液态玻璃（重要）

液态玻璃 API（`glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass)`）只存在于
**Xcode 26 / Swift 6.2 / iOS 26 SDK**。源码里用了**双层门禁**：

```swift
#if compiler(>=6.2)              // 编译期：当前工具链是否有这些符号
if #available(iOS 26.0, *) {     // 运行期：设备是否 iOS 26+
    content.glassEffect(...)     // 真玻璃
} else {
    fallback(content)            // 旧系统降级观感
}
#else
fallback(content)                // 旧 Xcode：整段被编译掉
#endif
```

所以：

* 用 **Xcode 26+** 构建 → iOS 26 设备上是真液态玻璃，iOS 16~18 设备上自动降级；
* 用 **Xcode 16 或更早**构建 → 仍然能编译通过，只是全程使用降级观感。

`if #available` **不能**替代 SDK：它只是运行期门禁，旧 SDK 里那些符号不存在，
照样编译失败——这正是外层 `#if compiler` 存在的意义。

部署目标保持 **iOS 16.0**。

## 无付费账号：未签名 IPA + AltStore / Sideloadly / 爱思助手
1. 把整个目录推到 GitHub 仓库根目录。
2. Codemagic 里选 `ios-unsigned` 工作流，Start new build。
3. 下载 Artifacts 里的 `VNPlayer-unsigned.ipa`，用 AltStore 等工具签名安装（免费账号 7 天有效）。

> `codemagic.yaml` 里 `environment.xcode: latest` 会拿到当时最新的 Xcode。
> 想要真玻璃就确保构建机是 Xcode 26 及以上（`latest` 通常已经满足）。

## 有付费账号：TestFlight
改 Bundle ID（codemagic.yaml 与 pbxproj 两处），配好 App Store Connect 集成，运行 `ios-testflight`。

## 更新到手机
改完代码提交 → Codemagic 重新构建 → 下载新 ipa → 在 AltStore 里再装一次（同一个 App 会直接覆盖，存档保留）。

## 本机静态检查（没有 Mac 也能跑）
`tools/` 下的 Python 脚本用于在没有编译器的情况下验证最容易出错的部分：

```bash
python tools/check_pbxproj.py VNPlayer.xcodeproj/project.pbxproj   # 工程文件自检：新增文件是否漏加进编译/资源阶段
python tools/ref_script_parser.py                                   # 脚本解析逻辑的等价移植 + 测试集
python tools/xp3_toolkit.py                                         # XP3 读写往返测试（含畸形与恶意样本）
python tools/ref_game_detect.py                                     # 游戏探测逻辑（目录 / 封包 / 两者并存）
python tools/ref_compat_report.py                                   # 兼容性报告判定（"该走哪条路线"的结论逻辑）
python tools/make_test_game.py Resources/TestXP3                    # 重新生成内置的 XP3 自检包
python tools/xp3_verify_independent.py Resources/TestXP3/data.xp3   # 用独立实现交叉验证自检包是否合规
```

它们不替代真机构建，但能在提交前抓住这类静默故障：

* 新增 `.swift` 忘了加进 `PBXSourcesBuildPhase`（Xcode 不报错，那个文件就是没被编译）；
* 资源文件夹忘了加进 `PBXResourcesBuildPhase`（运行期 `Bundle.main.url(forResource:)` 返回 nil）；
* 脚本解析的编码探测 / 警告去重 / 行号对齐写错；
* 游戏探测的优先级写错（脚本在子目录时 root 指错、外部脚本把封包挤掉这类问题）；
* XP3 字节布局写错（用自造的畸形与恶意样本覆盖越界、谎报长度、受保护条目等分支）。
  `xp3_toolkit.py` 会生成并验证这些边界样本：压缩/未压缩索引、多个 `0x80` continue 标志、
  未知顶层 chunk、NUL 计入/不计入字符数、**多段条目**、**内嵌在 exe 里（MZ 前缀，所有偏移加 base）**、
  **旧式分裂索引**、**krkrz 变体头**、受保护条目、截断文件，以及越界偏移 / 谎报长度等恶意输入。

最后一项的强度说明：`xp3_verify_independent.py` 是**另一个独立实现**（仅依据格式规范写成，
没看过本项目代码）。两个独立实现对同一份 `data.xp3` 得出的文件表、大小与 Adler-32 完全一致，
说明样本合规；这比"自己写自己读"更有说服力，但仍不等同于用真实游戏封包验证过。

## 装到手机后建议先跑一遍自检
游戏库里有「XP3 自检示例（内置）」：它的素材全部装在 `data.xp3` 里。
能正常看到渐变背景、立绘、听到音乐与音效、选项分支能走通，就说明封包这一层是好的。
点卡片右侧的听诊器图标可以看到这次载入的完整诊断（脚本来源、封包文件数、缺失素材、iOS 不支持的格式）。
