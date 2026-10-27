# Timbre

A native Mac app for Google Voice (unofficial, not affiliated with Google), written in Swift on macOS's built-in WebKit. No Electron, no bundled
browser: the app is about 400 KB and WebKit updates with macOS, so there is nothing to keep current.

- Runs as a normal windowed app by default (Dock icon, resizable, remembers its size).
- **Menu Bar Mode** (Timbre menu, or right-click the menu bar icon) shows it as a panel under a
  speech-bubble icon with no Dock icon. The choice is remembered.
- Closing the window keeps the app running so texts still arrive. Cmd-Q quits.
- Notifications for new texts, microphone for calls, unread count on the Dock icon, Open at Login.
- Sign-in and call pop-ups open in a single extra window. Other links open in your browser.

## Build

Needs macOS 13+ and the Xcode command line tools (`xcode-select --install`). No Node.

```bash
native/build.sh
```

Writes `native/build/Timbre.app` (universal: Apple Silicon and Intel, ad-hoc signed) and
`native/build/Timbre.zip`. The app is self-contained, so you can copy it to any Mac.

It is not notarized. On another Mac, right-click it and choose **Open** the first time, or run
`xattr -cr "Timbre.app"`.

## Updates

Timbre updates itself from this repository's latest GitHub release. It checks on launch and every
6 hours, or on demand with **Check for Updates…** in the Timbre menu. It asks first, never restarts
while the microphone is in use (a call), then downloads `Timbre.zip`, checks it is the same app and
intact, swaps itself in place and reopens. For hands-off updates:
`defaults write local.googlevoice.native autoInstall -bool true`.

- The repository must be public for the updater to read it. For a private repository, store a token
  that can read it: `defaults write local.googlevoice.native githubToken <token>`.
- To ship a release: edit `native/VERSION`, then run `native/release.sh` (needs `gh` signed in).
- The first updater-enabled build (1.0.3) has to be installed by hand once.
- The app is only ad-hoc signed, so the updater trusts GitHub over HTTPS and the bundle ID, not a
  developer signature. Notarization would need a paid Apple Developer ID.

## Data and troubleshooting

- Your login is kept by WebKit in `~/Library/WebKit/local.googlevoice.native`. Delete it (app quit) to sign out.
- Request log, for sign-in problems: `defaults write local.googlevoice.native debugLog -bool true`, then
  read `~/Library/Logs/GoogleVoice.log`.
- Notifications work for pages that use the standard `Notification` API. Anything Google sends through a
  service worker will not reach the app.

## Layout

```
native/Sources/main.swift    the whole app
native/Info.plist            bundle info and microphone text
native/build.sh              builds the universal .app and zip (version from native/VERSION)
native/release.sh            builds and publishes a GitHub release
native/Sources/Updater.swift the self-updater
packaging/icon.icns, .png    app icon
assets/                      menu bar icon (template PNGs)
scripts/make-app-icon.py     regenerates the app icon (needs macOS sips/iconutil)
scripts/make-tray-icon.py    regenerates the menu bar icon
```

## License

[MIT](LICENSE) © 2026 Harold Menges. Open source: use, copy, modify and share it, keeping the copyright
notice. Timbre is unofficial and not affiliated with, endorsed by, or sponsored by Google. Google and
Google Voice are trademarks of Google LLC. If you fork it, please give it a name of your own.
