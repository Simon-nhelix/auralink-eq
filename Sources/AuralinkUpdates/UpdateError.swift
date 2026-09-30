import AuralinkLocalization
import Foundation

public enum UpdateError: Error, Equatable, LocalizedError {
    case offline, rateLimited, server(Int), badResponse, unsigned, insecureURL
    case download(String), badSignature, noAppInArchive, wrongApp, notNewer, codeSignature
    case unsupportedSystem, translocated, notWritable(String), install(String)

    public var errorDescription: String? {
        switch self {
        case .offline: return L10n.text("Connect to the internet to check for updates.")
        case .rateLimited: return L10n.text("GitHub is limiting requests. Try again later.")
        case .server(let code): return L10n.format("Update server returned HTTP %@.", String(code))
        case .badResponse: return L10n.text("The update information could not be read.")
        case .unsigned: return L10n.text("This release has no update signature. Download it from the release page.")
        case .insecureURL: return L10n.text("The update address must use HTTPS.")
        case .download(let reason): return L10n.format("Couldn't download the update: %@", reason)
        case .badSignature: return L10n.text("The update signature is invalid. The app was not replaced.")
        case .noAppInArchive: return L10n.text("The update archive must contain one app.")
        case .wrongApp: return L10n.text("The downloaded app does not match this release.")
        case .notNewer: return L10n.text("The downloaded app is not a newer version.")
        case .codeSignature: return L10n.text("The downloaded app is damaged. The app was not replaced.")
        case .unsupportedSystem: return L10n.text("This update requires a newer version of macOS.")
        case .translocated: return L10n.text("Move Auralink EQ to Applications before updating.")
        case .notWritable(let folder): return L10n.format("The app cannot be replaced in %@. Move it to a writable Applications folder.", folder)
        case .install(let reason): return L10n.format("Couldn't install the update: %@", reason)
        }
    }
}
