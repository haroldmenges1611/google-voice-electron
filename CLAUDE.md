# Timbre: working notes for Claude

Timbre is an unofficial Google Voice client. **Two apps, one behaviour**: Mac (Swift, WKWebView) and
Windows (C#, WinForms + WebView2). Keep them in step.

## The rule
Any feature or fix that is not platform-specific is made in **both** `native/` and `windows/`, then
`./check.sh` must pass (it compiles both, takes seconds). Say in the reply when something is
intentionally one-platform.

## Commands (repo root)
- `./check.sh`: compile-check both apps. Run after every change.
- `./build.sh [all|mac|windows]`: real builds. Mac: `native/build/Timbre.app` + `Timbre.zip`.
  Windows: `windows/build/Timbre-win-x64.exe`, `-arm64.exe`.
- `./release.sh`: check, build both, publish `v$(cat VERSION)` to GitHub with all three assets.
  Bump `VERSION` first. Only release when the user says so; they approve each push and release.
- Relaunch the Mac app after a build: `pkill -f "Timbre.app"; open native/build/Timbre.app`.

## Layout
```
VERSION                      the one version number, used by both builds and both updaters
native/Sources/main.swift    Mac app: windows, menus, modes, popups, permissions, notifications
native/Sources/FloatingNav.swift  Mac glass Back/Forward/Home/Reload (own child window)
native/Sources/Updater.swift Mac self-updater (zip, swaps the .app)
windows/MainForm.cs          Windows app: window, menus, tray, popups, permissions, notifications
windows/PopupForm.cs, NavigationBar.cs, Settings.cs, Updater.cs, Program.cs
```

## Behaviour both apps share (keep identical)
- Start on https://voice.google.com/. Main frame may only show https `*.google.com`; anything else opens
  in the default browser. Sign-in landing on `myaccount.google.com/?utm_source=sign_in_no_continue`
  redirects back to Voice.
- **One** popup at a time. A blank/script popup replaces the old one; a real Google URL loads into it.
  A link to voice.google.com from a non-Voice page loads in the main view.
- Microphone granted only while the app is active and only to Google; camera denied.
- Closing the window keeps the app running; the app menu's Quit really quits. Quit must never be blockable.
- Modes: normal window (default) and menu bar (Mac) / tray (Windows). Remembered.
- Menus: App, File, Edit, View, Go (Calls, Messages, Voicemail, Settings, Home), Window (Mac), Help.
  Sign Out / Switch Account clears website data then reloads Voice.
- Self-update from the latest GitHub release of `haroldmenges1611/timbre`, asking first, never mid-call (Mac).
- Navigation controls: Back, Forward, Home, Reload (Mac floating glass; Windows toolbar, since WebView2
  cannot have controls over it).

## Gotchas
- Mac bundle id stays `local.googlevoice.native` (keeps users signed in). Do not change it.
- Mac updater takes the first `.zip` asset; Windows updater takes `Timbre-win-<arch>.exe`. Never add
  another `.zip` to a release.
- Mac debug log: `defaults write local.googlevoice.native debugLog -bool true` then
  `~/Library/Logs/GoogleVoice.log`. Turn it off afterwards.
- Windows cannot be run from this Mac: it only compiles. Say so when reporting Windows changes.
- Do not copy credentials (gh token) into app settings to test. The repo is public, so the updater
  needs no token.
- The name must not use Google's marks. "for Google Voice" as a description is fine.
