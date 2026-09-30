import AuralinkLocalization
import SwiftUI

struct UpdateView: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Auralink updates")).font(Theme.Typo.title)
                    Text(L10n.format("Current version: %@", updates.currentVersion))
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            status
            if let offer = updates.offer {
                Text(L10n.format("Version %@ is available", offer.version.description)).font(Theme.Typo.headline)
                ScrollView {
                    Text(offer.notes.isEmpty ? L10n.text("No release notes were provided.") : offer.notes)
                        .font(Theme.Typo.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 160)
                .background(Theme.Palette.raised, in: RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm))
                Text(L10n.text("Installing restarts Auralink. Mac sound will be restored to your real output before the restart. Start System EQ again after the update."))
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L10n.text("Automatically check for updates"), isOn: $updates.automaticChecks)
                .toggleStyle(.checkbox).font(Theme.Typo.body)
            HStack(spacing: 10) {
                Button(L10n.text("Release page")) { updates.openReleasePage() }
                if updates.offer != nil, !updates.busy {
                    Button(L10n.text("Skip this version")) { updates.skip(); dismiss() }
                }
                Spacer()
                if case .downloading = updates.state {
                    Button(L10n.text("Cancel download")) { updates.cancelDownload() }
                } else if updates.canInstall {
                    Button(L10n.text("Install and restart")) { updates.install() }
                        .buttonStyle(.borderedProminent).tint(Theme.Palette.accent)
                } else if !updates.busy {
                    Button(L10n.text("Check for updates")) { updates.checkNow() }
                }
                Button(L10n.text("Close")) { dismiss() }
                    .disabled(updates.busy).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(24).frame(width: 540)
        .foregroundStyle(Theme.Palette.textPrimary)
        .background(Theme.Palette.surface)
        .onAppear { if updates.state == .idle { updates.checkNow() } }
    }

    @ViewBuilder private var status: some View {
        switch updates.state {
        case .idle: Text(L10n.text("Check for updates"))
        case .checking: ProgressView(L10n.text("Checking for updates…"))
        case .upToDate: Label(L10n.text("You're up to date."), systemImage: "checkmark.circle")
        case .available(let offer):
            if offer.signatureURL == nil {
                Text(L10n.text("This release has no update signature. Download it from the release page."))
                    .foregroundStyle(Theme.Palette.warning)
            }
        case .downloading(_, let received, let total):
            ProgressView(L10n.text("Downloading update…"), value: Double(received), total: Double(max(total, 1)))
        case .installing: ProgressView(L10n.text("Installing and restarting…"))
        case .failed(let message, _):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.Palette.warning).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct UpdateAvailableButton: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let offer = updates.offer {
            Button {
                openWindow(id: "updates")
            } label: {
                Label(L10n.format("Update available: %@", offer.version.description), systemImage: "arrow.down.circle")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L10n.text("Check for updates…")) {
                openWindow(id: "updates")
                updates.checkNow()
            }
        }
    }
}
