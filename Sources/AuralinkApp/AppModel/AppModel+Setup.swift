import Foundation
import AppKit

extension AppModel {
    // MARK: Setup helpers

    func openSetupGuide() {
        guard let url = setupGuideURL() else {
            lastError = "The setup guide was not found. Open docs/SETUP.md from the Auralink EQ source repository."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openBlackHoleDownload() {
        if let url = URL(string: "https://existential.audio/blackhole/") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAudioMIDISetup() {
        let url = URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            lastError = "Audio MIDI Setup.app was not found."
        }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func installBlackHoleWithHomebrew() {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralink-install-blackhole.command")
        let script = """
        #!/bin/zsh
        set -e
        clear
        echo "Auralink EQ - BlackHole 2ch installer"
        echo
        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew was not found on this Mac."
          echo "Opening the official BlackHole download page instead..."
          open "https://existential.audio/blackhole/"
          echo
          echo "Install BlackHole 2ch, then return to Auralink and click Refresh."
          echo
          read -k 1 "?Press any key to close this window."
          exit 1
        fi
        echo "Running: brew install blackhole-2ch"
        echo
        brew install blackhole-2ch
        echo
        echo "Done. If BlackHole 2ch does not appear immediately, log out/in or reboot."
        echo "Opening Audio MIDI Setup and Sound Settings..."
        open "/Applications/Utilities/Audio MIDI Setup.app" || true
        open "x-apple.systempreferences:com.apple.Sound-Settings.extension" || true
        echo
        echo "After routing system audio to BlackHole, return to Auralink and click Refresh."
        echo
        read -k 1 "?Press any key to close this window."
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
            statusMessage = "Opened BlackHole installer in Terminal."
        } catch {
            lastError = "Couldn't start BlackHole installer: \(error.localizedDescription)"
            openBlackHoleDownload()
        }
    }

    func setupGuideURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["AURALINK_SETUP_GUIDE_URL"],
           let url = URL(string: override), !override.isEmpty {
            return url
        }

        let fm = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: "SETUP", withExtension: "md"),
            URL(fileURLWithPath: "docs/SETUP.md",
                relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
        ].compactMap { $0 }
        return candidates.first(where: { fm.fileExists(atPath: $0.path) })
    }
}
