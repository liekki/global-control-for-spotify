// Updates - checks GitHub for a newer release and, when you choose to, installs it (Update.cs does the same on Windows).
// One unauthenticated request to GitHub's API, once a day at most (CheckForUpdates=false turns it off). Installing
// downloads the release's zip, checks it holds this app, and swaps the app bundle in place once this copy has quit.
import Cocoa

struct Release {
    var version: [Int]
    var tag = "", page = "", zip = "" // zip: the macOS download's URL, "" if the release has none
}

enum Updates {
    static let repo = "liekki/spotify-global-hotkeys", zipName = "SpotifyGlobalHotkeys-macOS.zip"

    // From Info.plist, which build.sh stamps from APP_VERSION (CI: the release tag). Local builds are 0.0.0.
    static var current: [Int] {
        parseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? [0, 0, 0]
    }
    static var isDevelopmentBuild: Bool { current == [0, 0, 0] }

    static func display(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

    // "v1.4.0" -> [1, 4, 0], "1.4" -> [1, 4, 0]; anything else (including "v1.4.0-beta") -> nil.
    static func parseVersion(_ tag: String) -> [Int]? {
        let s = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func isNewer(_ release: Release?) -> Bool {
        guard let release, !isDevelopmentBuild else { return false }
        return current.lexicographicallyPrecedes(release.version)
    }

    static func parse(_ data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let tag = json["tag_name"] as? String ?? ""
        guard let version = parseVersion(tag) else { return nil }
        var release = Release(version: version, tag: tag, page: json["html_url"] as? String ?? "")
        for asset in json["assets"] as? [[String: Any]] ?? [] where asset["name"] as? String == zipName {
            release.zip = asset["browser_download_url"] as? String ?? ""
        }
        return release
    }

    // Blocks: call it off the main thread.
    static func latest() throws -> Release? {
        // SGH_UPDATE_URL points the check elsewhere (a local file, for testing an update without publishing one).
        let override = ProcessInfo.processInfo.environment["SGH_UPDATE_URL"] ?? ""
        guard let url = URL(string: override.isEmpty ? "https://api.github.com/repos/\(repo)/releases/latest" : override) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("SpotifyGlobalHotkeys", forHTTPHeaderField: "User-Agent") // GitHub requires one
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return parse(try fetch(request))
    }

    private static func fetch(_ request: URLRequest) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Data?, failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { failure = JumpError("GitHub answered \(http.statusCode).") }
            result = data; failure = failure ?? error
            done.signal()
        }.resume()
        done.wait()
        if let failure { throw failure }
        return result ?? Data()
    }

    // The app can replace itself when its folder is writable (Applications is, for an admin user). A copy macOS
    // runs from a random read-only place (opened from Downloads without moving it first) can't.
    static var canReplace: Bool {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" && !bundle.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    // Downloads and unpacks the release, then starts a helper that waits for this app to quit, swaps the bundle
    // and opens the new one. The caller quits right after. Blocks: call it off the main thread.
    static func install(_ release: Release) throws {
        guard let url = URL(string: release.zip), !release.zip.isEmpty else { throw JumpError("This release has no Mac download.") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SpotifyGlobalHotkeys-update-\(display(release.version))-\(getpid())")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(zipName)
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("SpotifyGlobalHotkeys", forHTTPHeaderField: "User-Agent")
        try fetch(request).write(to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = work.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        // Only ever put this same app in place of itself.
        guard unzip.terminationStatus == 0, let id = Bundle(url: app)?.bundleIdentifier, id == Bundle.main.bundleIdentifier else {
            throw JumpError("The download doesn't look like Spotify Global Hotkeys.")
        }

        // Keep the old copy until the new one is in place, and put it back if the move fails.
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2.old"
            if mv "$2" "$2.old"; then
              if mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
            fi
            open "$2"
            rm -rf "$4"
            """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", String(getpid()), Bundle.main.bundleURL.path, app.path, work.path]
        try swap.run()
    }
}
