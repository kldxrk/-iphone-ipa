# Xcode 项目设置

在没有 Mac 的情况下，推荐先在 Codemagic 使用一个最小 SwiftUI iOS 项目作为宿主，
然后把 Sources/VNPlayer 中的源码加入 target。

Bundle Identifier：
com.example.vnplayer

Deployment Target：
iOS 16.0+

需要加入：
- Sources/VNPlayer/*.swift
- Resources/demo.json

之后再运行 codemagic.yaml 的 workflow。
