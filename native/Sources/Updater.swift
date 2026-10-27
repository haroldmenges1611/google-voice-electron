// Updates the app from the latest GitHub release. Checks on launch and every few hours, asks before
// installing (unless `defaults write local.googlevoice.native autoInstall -bool true`), never restarts
// during a call, and replaces the .app in place.
//
// The repository comes from the TimbreUpdateRepo key in Info.plist ("owner/name"). A private
// repository needs a token: `defaults write local.googlevoice.native githubToken <token>`.

import Cocoa

final class Updater {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]
    }

    private let repo = Bundle.main.object(forInfoDictionaryKey: "TimbreUpdateRepo") as? String ?? ""
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var checking = false
    private var promptedVersion: String?
    private var timer: Timer?

    /// Returns true while a call may be in progress, so the app is not restarted under it.
    var isBusy: () -> Bool = { false }

    private var token: String? {
        let value = UserDefaults.standard.string(forKey: "githubToken")
        return (value?.isEmpty == false) ? value : nil
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    func check(manual: Bool) {
        guard !checking, !repo.isEmpty else { return }
        checking = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data, status == 200, let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    debugLog("update check failed: status \(status) \(error?.localizedDescription ?? "")")
                    if manual {
                        self.alert("Couldn't check for updates",
                                   "GitHub answered \(status == 0 ? "nothing" : String(status)). If the repository is private, set a token (see the README).")
                    }
                    return
                }
                self.handle(release, manual: manual)
            }
        }.resume()
    }

    private func handle(_ release: Release, manual: Bool) {
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard latest.compare(currentVersion, options: .numeric) == .orderedDescending else {
            if manual { alert("Timbre is up to date", "You have version \(currentVersion).") }
            return
        }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            if manual { alert("Update \(latest) has no download", "The release has no .zip attached.") }
            return
        }
        if isBusy() {
            if manual { alert("Update \(latest) is available", "Timbre is on a call. Try again when it ends.") }
            return
        }
        let auto = UserDefaults.standard.bool(forKey: "autoInstall")
        if !manual && !auto && promptedVersion == latest { return } // asked once this run; ask again next launch
        promptedVersion = latest

        if !auto {
            NSApp.activate(ignoringOtherApps: true)
            let box = NSAlert()
            box.messageText = "Timbre \(latest) is available"
            box.informativeText = "You have \(currentVersion).\n\n" + String((release.body ?? "").prefix(400))
            box.addButton(withTitle: "Install and Restart")
            box.addButton(withTitle: "Later")
            if box.runModal() != .alertFirstButtonReturn { return }
        }
        install(asset: asset, version: latest, releasePage: release.html_url)
    }

    private func install(asset: Release.Asset, version: String, releasePage: String) {
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            alert("Can't update in place", "Timbre isn't in a folder you can write to. Opening the download page instead.")
            if let url = URL(string: releasePage) { NSWorkspace.shared.open(url) }
            return
        }

        // With a token, download through the API (works for private repositories).
        var request: URLRequest
        if let token = token {
            request = URLRequest(url: URL(string: asset.url)!)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request = URLRequest(url: URL(string: asset.browser_download_url)!)
        }
        URLSession.shared.downloadTask(with: request) { [weak self] file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<URL, Error>
            if let file = file, status == 200 {
                result = Result { try Updater.unpack(zip: file, expectedVersion: version) }
            } else {
                result = .failure(error ?? NSError(domain: "Updater", code: status,
                                                   userInfo: [NSLocalizedDescriptionKey: "download failed (\(status))"]))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let newApp): self?.replaceAndRelaunch(with: newApp)
                case .failure(let failure): self?.alert("Update failed", failure.localizedDescription)
                }
            }
        }.resume()
    }

    /// Unzips and checks the app is Timbre, newer, and intact. Returns the path of the new .app.
    private static func unpack(zip: URL, expectedVersion: String) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("timbre-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let apps = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first, let bundle = Bundle(url: app) else { throw failure("the download has no app in it") }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw failure("the download is a different app") }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard version.compare(current, options: .numeric) == .orderedDescending else {
            throw failure("the download is version \(version), not newer than \(current)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func replaceAndRelaunch(with newApp: URL) {
        // A small script waits for this process to exit, swaps the app, and opens the new one.
        // The new app keeps its own name (a rename from an older release takes effect here).
        let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(newApp.lastPathComponent)
        let script = """
        #!/bin/sh
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && mv "$3" "$4"; then
          rm -rf "$2.old"
        elif [ ! -d "$2" ] && [ -d "$2.old" ]; then
          mv "$2.old" "$2"
          exit 1
        fi
        xattr -cr "$4" 2>/dev/null
        open "$4"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("timbre-update.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                                 Bundle.main.bundleURL.path, newApp.path, destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            alert("Update failed", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw failure("\((tool as NSString).lastPathComponent) failed") }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let box = NSAlert()
        box.messageText = title
        box.informativeText = text
        box.runModal()
    }
}
