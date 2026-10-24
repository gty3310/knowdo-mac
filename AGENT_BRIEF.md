# 知行 KnowDo for Mac — 工程守则

给在本机协作的 AI（如 Claude Code）或开发者：动手前先读完本文件。
本文件是契约：修编译错误、做本地调试时必须遵守；若发现代码与本文件冲突，**停下来报告，不要自行改语义**。

## 这个工程是什么

- 知行 KnowDo 的 Mac 客户端（SwiftUI，macOS 14+），与安卓版（github.com/gty3310/knowdo）共用同一个 Google Drive 桥文件 `tasks.json` 同步任务数据。
- 手机、Mac、Muse 三方都在读写同一个桥文件。Mac 端任何「为了过编译」而改掉数据格式或同步语义的修改，都会在另外两方身上爆出来——这是本工程最贵的错误类型。

## 数据契约（绝不能改）

- 桥文件顶层键：`app / schemaVersion / tasks / guardEvents / schedule / updatedAt / updatedBy`。未知顶层键、未知任务字段一律原样保留（`JSONValue` 就是为此存在的；不要换成强类型 Codable 把未知字段吞掉）。
- `schedule` 是 Muse 排的日程：本 App **只读**，回写时原样带回，绝不生成或修改其内容。
- 同步四条铁律（安卓 v1.5.3 用一整晚的事故换来的）：
  1. 没变化绝不回写（按 `id → updatedAtMs` 签名做语义比较，一致就跳过回写）；
  2. 写之前重新读一遍最新文件再合并；
  3. 合并按 id 对齐、`updatedAtMs` 新者胜、`deleted=true` 的墓碑不许复活；
  4. 写后回读校验任务 id 集合，丢了就并集补写一次。
- 任务字段全集（JSON 键名不可改名）：`id / title / scenarios / deadline / deadlineTime / nextStartAt / repeat / durationMinutes / actualMinutes / priority / status / note / focusRule / focusMode / blockedApps / allowedApps / primaryApp / doneDates / autoStart / deleted / createdAtMs / updatedAtMs`；另有 `createdAt / updatedAt` 的 ISO 字符串与毫秒双写（安卓 TaskItem 的既有格式），保持双写不要删。
- 写桥时 `updatedBy` 写 `"knowdo-mac"`。
- 本地 session 段（`~/Library/Application Support/KnowDoMac/`）只存本机计时段，永不进桥。

## 语义契约（修错时不要顺手改）

- 计时：全局最多一个计时中 ＋ 一个暂停槽；暂停槽被新暂停顶替时，旧任务回到未开始。
- `markDone / markUndone / isDoneToday` 的口径与安卓 `TaskItem.java` 一致（doneDates 按本地日期）。
- `TaskInfo.swift` 的 buildTaskInfo 文案、字段顺序、措辞逐字对齐安卓 `AiLaunchActivity.buildInfo`——从 Mac 复制出去的任务信息要和手机复制的一模一样。
- 日历页 `freeMinutes` 与「问 AI」文案对齐安卓 `CalendarActivity` 的算法与结构。
- `nextStartAt` 到点弹开始页；开始计时后清掉该次 nextStartAt 并写回桥。`autoStart=true` 且当前无计时在跑时自动开始，并清掉标志写回桥。
- 过半检查页（到目标时长一半、每个任务每次只弹一次）三键：继续计时／就此完成／暂停休息。结束页 Time's up：+5/+15/+25 分钟（快捷键 Q/W/E）、自定义加时、Mark Complete（回车确认，「Enter to complete」）。
- 已知口径差（不要在修编译时动它，留待 Jarvis 与用户统一）：悬浮面板「已用」目前 Mac 算的是今日 session 累计，安卓 v1.6.1 算的是全部历史段累计；同任务两边数字可能对不上，是已登记的差异，不是 bug 修复机会。

## 设计语言

参照 Smart Countdown Timer（用户朋友的作品，用户定为知行统一风格）：

- 菜单栏常驻「任务名 ＋ 倒计时」；
- 深色半透明悬浮面板：左侧剩余时间大字，右侧小字「已用 / 总计划」，下接按钮排与笔记区（笔记框右上角有「复制」按钮）；
- 全屏页极简：整屏深色、内容居中、按钮带快捷键字母、主操作回车确认。

## 明确不在 v0.1 范围（不要顺手加）

专注守卫的拦截执行（focus 字段只同步和编辑）、屏幕内容守卫、Google Calendar 接入、子任务、UNUserNotificationCenter 通知（开始提醒走全屏页）。

## 编译与试跑

- 用 Xcode 打开 `KnowDoMac.xcodeproj` 直接 Run；无第三方依赖；ad-hoc 签名、不开沙盒（桥文件靠 security-scoped bookmark 访问）。
- 登录项（SMAppService）：从 Xcode 的 DerivedData 路径运行时，系统可能拒绝注册登录项——这不是 bug；把构建出的 App 放进 `/Applications` 后再试。设置页显示的是真实注册状态。
- 手写 pbxproj 若被新版 Xcode 打开时自动升级改写，属正常。

## 修错流程

- 每修一轮 git 提交一次，提交信息写清改了哪个文件、为什么。
- 全部跑绿之后，把 `git log --oneline` 与累计 diff 的概要发回给用户 / Jarvis 做语义审查，确认没碰数据契约和语义契约，再正式使用。
