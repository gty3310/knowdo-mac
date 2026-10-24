# KnowDo for Mac 知行

**The Unity of Knowledge and Action.**

KnowDo for Mac is the macOS companion to KnowDo: a SwiftUI menu-bar and floating-window app for the same Excel-like task list and focus timer. It signs in with the same account as the Android app and syncs through Supabase in realtime — including a single logical timer shared across devices, so a countdown started on your phone counts down on your Mac too. (The Google Drive file bridge the first version used has been removed.)

This app is **early and in active development**. Its feature set has not yet caught up with Android; the list below says plainly what is in and what is not.

> **Related project — [KnowDo for Android](https://github.com/gty3310/knowdo):** the original KnowDo app — an Excel-like task list and focus timer for Android with full-screen check-ins, a focus guard, a screen-content guard, per-task alarms, and the same account and Supabase sync as this Mac app. If you only install one of the two, start there; they are designed to run as a pair.

## Vision

KnowDo is built around one job: at any moment, you know exactly what you should be doing — and the moment you drift, it notices and brings you back.

It is designed for an ADHD mind. Long tasks invite drift, and the most dangerous moment is the gap between finishing one task and starting the next. KnowDo attacks both failure points:

- Tasks break into subtasks of about 5–10 minutes each, edited right inside an always-on floating window that counts down the current subtask, not just the whole task.
- When a task ends and the next one hasn't started, KnowDo asks — full-screen — what comes next, how long it will take, and until when. No gap, no drift.
- On the computer, it understands what is on your screen and whether it matches your current task. If you are off-task, it doesn't slam the door: it asks how much longer you want, and then holds you to your own answer.

The long-term goal is a true body-doubling companion, in the spirit of Overlord: aware of your screen, able to talk with you while you work, able to call you when a pop-up is not enough, with real consequences for going off-plan — combined with Motion-style automatic rescheduling and a Sunsama-style daily rhythm of planning the day against your calendar and reviewing it in the evening. One Excel-like task list, on phone and computer, always in sync, so the next action is never in doubt.

## Roadmap

In priority order:

1. **Subtasks in the floating window** — split a task into subtasks, give each its own duration, and keep the current subtask's remaining time front and center.
2. **Between-task guard** — the moment a task ends without a successor, a full-screen prompt asks what is next, for how long, and until when. A phone-call version follows.
3. **Mac screen-context guard** — judge whether what is on screen matches the current task; ask "how much longer?", then close the app when the time you named is up.

Later: real phone calls for task transitions, monetary fines for going off-plan, an all-day conversational body-doubling companion, and Motion-style automatic rescheduling.

## Latest release

**v0.5.0** (2026-10-24): between-task guard (a full-screen "What's next?" whenever nothing is running), pause mode (every pause needs a purpose and a length, with a timed call-back and a silent option), idle nagging with strictness profiles (shared with the phone through the cloud), a floating-window "come back in…" choice on close, and an in-app changelog. Full history: [CHANGELOG.md](CHANGELOG.md).

## Features (current)

The design language follows Smart Countdown Timer, a companion app by a friend of the author: task name + countdown always in the menu bar, a dark translucent floating window, and minimal full-screen pages.

- **Main window task table** — aligned with the Android layout: checkbox, task name, context tags, deadline (date + time), planned start time, planned vs. actual minutes, priority, focus markers, ▶/⏸, and a per-row menu (edit / complete / copy task info / reset timing / delete). A full edit sheet covers every field, including daily repeat, notes, and the focus fields (description, mode, primary app, block/allow lists).
- **Timer engine** — one running timer plus one paused slot, with the same semantics as Android. Half-time and the end arrive as minimal full-screen pages: Time's up offers extensions with Q/W/E keyboard shortcuts and Mark Complete on Return; completing writes the completion back through sync.
- **Menu bar** — always shows the current task name and remaining time, with a small menu to start/pause, open the main window or calendar, or quit.
- **Floating panel** — always on top, draggable, remembers its position, and shows the current top task (timing first, then paused, then the first unfinished one): big remaining time, time used vs. planned, start/pause, complete, open KnowDo, and a quick note editor that saves as you stop typing.
- **Calendar window** — today's vertical timeline with planned blocks (read-only) and actual timed blocks side by side, a red "now" line, a day overview (done / remaining / minutes still free until 22:30), and an "Ask AI" button that copies a summary of the day to the clipboard for planning in chat.
- **Start-time reminders** — when a task's planned start time arrives, a full-screen page offers: start timing, snooze 10 minutes, or ignore.
- **Auto-start** — a task flagged `autoStart` (for example, written by your assistant in chat) starts timing on its own when it arrives and nothing else is timing.
- **Account and Supabase sync** — email sign-in; tasks sync in realtime and merge with the same rules as Android (align by id, newest wins, tombstone deletes, unknown fields preserved verbatim). The day's `schedule` is maintained externally and only read here. A per-account local cache keeps the task list viewable offline; signing out clears the cache and the in-memory list — when signed out, the app shows no tasks.
- **Launch at login** — registered as a login item by default (toggle in Settings); most reliable once the app lives in the Applications folder.

## Not yet on Mac

Focus-guard enforcement (the focus fields sync and are editable, but nothing is blocked yet), the screen-content guard, per-task alarms, and subtasks. See the Roadmap above.

## Build & run

Requires macOS 14+ and Xcode 15 or so.

1. Open `KnowDoMac.xcodeproj`, select the KnowDoMac scheme, and Run (⌘R). The project uses ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`), so no developer account is needed to run it yourself.
2. For daily use, copy the built `KnowDoMac.app` into your Applications folder before opening it — the launch-at-login registration is only stable from there.
3. First launch: sign in with your KnowDo account (the same email as on Android). There is no local task file to pick anymore; tasks come from the cloud account.

Cloud sync uses a Supabase **publishable** key supplied through a local, untracked file in the project root (`supabase_key.txt`); it is never committed. See `AGENT_BRIEF.md` for the data contract both apps share.

## Sync notes

- Conflicts on the same task resolve newest-wins by update timestamp; deletes are tombstones and never resurrect.
- Fields the Mac app does not know are preserved verbatim on write-back.
- "Time used" session history is kept per device; task completion state is what syncs. The shared timer state itself lives in the cloud, and either device can control the one logical timer.

## Known limitations

- Early software: sync and the timer are in daily use, but expect rough edges; the offline cache in particular has not yet been through a full real-device test pass.
- Quitting the app parks a locally running timer as paused; it resumes on the next launch.
- The custom-minutes field on the Time's up page treats Q/W/E as extension shortcuts — type digits there, not letters.
- No app icon yet (the asset catalog is empty); it does not affect running the app.
- The app is not sandboxed and is not on the Mac App Store.

## License

Licensed under [CC BY-NC-SA 4.0](LICENSE): free to use, modify and build upon, **non-commercial only**, and derivatives must be shared alike and remain free.

Courtesy (not a license condition): please let the author know before you build on it.
