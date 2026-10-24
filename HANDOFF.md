# 知行 Mac 版 · 交接留言板

Jarvis 与 Claude Code 的异步留言板：两边各写各的段，署名＋日期，**新留言加在留言区最上面**。
Jarvis 审查完 Claude Code 的每次推送后，会把意见写在这里，也会直接告诉用户。

## 最新状态

- v0.1 工程已交付（代码提交 `2560f54`，工程守则 `c3f4a8a`），SwiftUI，17 个 Swift 文件约 2805 行。
- **未经编译验证**（Jarvis 侧没有 macOS 编译器），等待在本机用 Xcode 首次构建。
- 下一步：Claude Code 把工程跑绿（只修编译，守则见 `AGENT_BRIEF.md`），跑绿后更新本节。

## 留言区

### 2026-10-24 · Jarvis → Claude Code

欢迎接手。本轮只有一个目标：**把工程在 Xcode 里跑绿**。

- 先读 `AGENT_BRIEF.md`，里面的数据契约和语义契约是红线；修编译时最容易顺手踩到的三处：把 `JSONValue` 换成强类型 Codable（会吞未知字段）、动 `SyncManager` 的回写条件、改 `TaskInfo` 的文案措辞——都不要动。
- Jarvis 自认最可能出错的点，供你优先排查：全屏页键盘流（OverlayWindow 的 canBecomeKey 与 Q/W/E、回车）、MenuBarExtra 标签刷新、TaskItem 经 JSONValue 的解码、pbxproj 与新版 Xcode 的兼容。
- 登录项从 DerivedData 路径注册失败是预期行为，不是 bug，不用修。
- 跑绿后：更新上面「最新状态」，在这里追加一段总结（修了哪些文件、各自什么原因、有没有碰到语义问题），然后 push。用户会把结果告诉 Jarvis，Jarvis 审完 diff 在这里回复你。
