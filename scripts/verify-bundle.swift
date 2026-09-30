// Resource smoke check for both native SwiftPM and Universal/Xcode layouts.
import Foundation

guard CommandLine.arguments.count == 2,
      let app = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])),
      let resources = app.resourceURL else { fatalError("expected an app bundle") }
guard let core = Bundle(url: resources.appendingPathComponent("Auralink_AuralinkCore.bundle")),
      let localization = Bundle(url: resources.appendingPathComponent("Auralink_AuralinkLocalization.bundle")) else {
    fatalError("packaged resource bundles could not be opened")
}
for file in ["target-curves", "safety-rules"] {
    guard let url = core.url(forResource: file, withExtension: "json", subdirectory: "data") else {
        fatalError("missing packaged knowledge file: \(file)")
    }
    _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
}
for language in ["en", "ko", "ja"] {
    guard let path = localization.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path),
          let table = bundle.url(forResource: "Localizable", withExtension: "strings"),
          let strings = try PropertyListSerialization.propertyList(from: Data(contentsOf: table), format: nil) as? [String: String],
          strings["Check for updates…"] != nil else { fatalError("missing packaged update translation: \(language)") }
}
print("Packaged knowledge and en/ko/ja update translations verified.")
