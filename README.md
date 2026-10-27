# Google Voice menu bar app (macOS, Chromium)

A menu bar app that shows Google Voice in a panel. Click the speech-bubble icon, sign in once, and
the login is kept between launches. New texts show as macOS notifications. No Dock icon.

This replaces the Swift version in `../google-voice-menubar`. That one used WebKit, which Google can
refuse to sign into. This one runs on Electron, which bundles Chromium, and sends Chromium's normal
user agent.

## Run it on your Mac

You need Node.js 20 or later (tested with Node 24) and the Xcode command line tools
(`xcode-select --install`).

```bash
cd apps/google-voice-electron      # wherever you unpacked it
npm install                        # downloads Electron for your Mac
npm start                          # runs the app from the source folder
```

## Build the app

```bash
npm run package
```

This writes `dist/Google Voice-darwin-arm64/Google Voice.app` on Apple Silicon, or `darwin-x64` on
Intel. Copy it to `/Applications`.

The app is not code-signed. The first time, right-click it and choose **Open**, then confirm.

## Notifications

1. Sign in. When a new text arrives, macOS asks whether Google Voice may send notifications. Allow it.
   You can also set this in **System Settings → Notifications → Google Voice**.
2. Clicking a notification opens the panel.

The app catches notifications the page creates through the standard `Notification` API, and also
`registration.showNotification` called from the page. If Google Voice sends notifications another
way (for example from a service worker), they will not reach the app. That needs a test with a
signed-in session.

## Sign-in

Google's sign-in page is opened in the panel. Pop-ups for sign-in open as separate windows in the
same session. The app sends Chromium's normal user agent, which should avoid the "browser may not be
secure" refusal. That is not verified yet. If Google still refuses, copy the exact message and send
it to me.

## Settings and data

- **Open at Login**: right-click the icon. Works best with the copy in `/Applications`.
- **Reset the session**: quit the app and delete `~/Library/Application Support/Google Voice`
  (when built) or `~/Library/Application Support/google-voice-electron` (when run with `npm start`).
- **Calls** use the microphone. macOS asks for permission the first time.

## Tests

```bash
npm test
```

- `test/policy.test.js`: URL, permission and notification rules, plus the user agent.
- `test/e2e.test.js`: starts the app in Electron's Chromium, points it at a local page that creates a
  notification, and checks the text reaches the app. The app runs without a display, and the test
  also checks that the user agent has no "Electron" token.

On Linux the Electron binary needs GTK and NSS libraries. The e2e test was run here with them in a
user folder, via `LD_LIBRARY_PATH`. On a Mac that is not needed.

The e2e test does not check that macOS shows the notification banner. That needs a Mac.

## Not covered yet

- Clicking a notification opens the panel. It does not call the page's own click handler.
- The app icon in `/Applications` is Electron's default. Only the menu bar icon is custom.
- No automatic updates.
- Google sign-in and the actual notification path have not been tried with a real Google account.

## Layout

```
package.json                  scripts: start, test, package
src/main.js                   menu bar icon, panel window, notifications, permissions, menus
src/preload.js                notification bridge: replaces window.Notification inside the page
src/policy.js                 pure rules (Google URLs, permissions, user agent, notification text)
assets/                       menu bar icon (template PNGs), copied next to the packaged app
packaging/extend-info.plist   LSUIElement: no Dock icon
scripts/make-tray-icon.py     regenerates the icon PNGs (standard library only)
test/                         unit tests and the Electron end-to-end test
```
