import Foundation
import XCTest
@testable import AuralinkLocalization

final class LocalizationTests: XCTestCase {
    func testLanguageSelectionUsesPreferencesAndEnglishFallback() {
        XCTAssertEqual(L10n.language(for: ["ko-KR", "en-US"]), "ko")
        XCTAssertEqual(L10n.language(for: ["ja-JP", "ko-KR"]), "ja")
        XCTAssertEqual(L10n.language(for: ["en-GB"]), "en")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "ja-JP"]), "ja")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "de-DE"]), "en")
        XCTAssertEqual(L10n.language(for: []), "en")
    }

    func testLocalizedLookupAndUnknownKeyFallback() {
        XCTAssertEqual(L10n.text("Start System EQ", language: "en"), "Start System EQ")
        XCTAssertEqual(L10n.text("Start System EQ", language: "ko-KR"), "시스템 EQ 시작")
        XCTAssertEqual(L10n.text("Start System EQ", language: "ja-JP"), "システムEQを開始")
        XCTAssertEqual(L10n.text("Start System EQ", language: "fr"), "Start System EQ")
        XCTAssertEqual(L10n.text("An unknown key", language: "ja"), "An unknown key")
    }

    func testEveryLanguageHasMatchingNonemptyKeysAndFormatArguments() throws {
        let english = try strings(language: "en")
        XCTAssertGreaterThan(english.count, 300)
        for language in L10n.supportedLanguages {
            let localized = try strings(language: language)
            XCTAssertEqual(Set(localized.keys), Set(english.keys), language)
            for (key, value) in localized {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): \(key)")
                XCTAssertEqual(try placeholders(value), try placeholders(english[key]!), "\(language): \(key)")
            }
        }
    }

    func testPluralRulesAndMixedTemplates() throws {
        for language in L10n.supportedLanguages {
            let rules = try propertyList(language: language, name: "Localizable", extension: "stringsdict")
            XCTAssertEqual(rules.count, 8)
            for (key, value) in rules {
                let entry = try XCTUnwrap(value as? [String: Any])
                let count = try XCTUnwrap(entry["count"] as? [String: String])
                XCTAssertEqual(count["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType")
                XCTAssertEqual(count["NSStringFormatValueTypeKey"], "lld")
                XCTAssertNotNil(count["other"], key)
                if language == "en" { XCTAssertNotNil(count["one"], key) }
            }
        }
        XCTAssertEqual(L10n.format("%lld active bands", 0, language: "en"), "0 active bands")
        XCTAssertEqual(L10n.format("%lld active bands", 1, language: "en"), "1 active band")
        XCTAssertEqual(L10n.format("%lld active bands", 2, language: "en"), "2 active bands")
        XCTAssertEqual(L10n.format("%lld active bands", 1, language: "ko"), "활성 밴드 1개")
        XCTAssertEqual(L10n.format("%lld active bands", 2, language: "ja"), "有効なバンド：2本")
        XCTAssertEqual(L10n.format("%lld bands · %@", 1, "User", language: "en"), "1 band · User")
        XCTAssertEqual(L10n.format("%lld bands · %@", 2, "사용자", language: "ko"), "밴드 2개 · 사용자")
        XCTAssertEqual(L10n.format("%lld active bands · preamp %@", 1, "−3.0 dB", language: "en"), "1 active band · preamp −3.0 dB")
        XCTAssertEqual(L10n.format("%lld active bands · preamp %@", 2, "−3.0 dB", language: "ja"), "有効なバンド：2本 · プリアンプ −3.0 dB")
    }

    func testFormattingReordersArgumentsAndPreservesUserContent() {
        let key = "Auralink couldn't restart the audio engine (%@) after %@ attempts, so Mac sound was restored to a real output device."
        XCTAssertEqual(
            L10n.format(key, "device 100%", "3", language: "ko"),
            "3회 시도 후에도 오디오 엔진을 다시 시작하지 못해(device 100%) Mac 사운드를 실제 출력 기기로 복원했습니다."
        )
        let presetName = "My 日本語 EQ 100% \"test\""
        XCTAssertEqual(
            L10n.format("Applied \"%@\"", presetName, language: "ja"),
            "「\(presetName)」を適用しました"
        )
    }

    func testLocalizedPrivacyCopyIsPresentForEveryLanguage() throws {
        for language in L10n.supportedLanguages {
            let copy = try propertyList(language: language, name: "InfoPlist", extension: "strings")
            XCTAssertEqual(copy["CFBundleDisplayName"] as? String, "Auralink EQ")
            let usage = try XCTUnwrap(copy["NSMicrophoneUsageDescription"] as? String)
            XCTAssertTrue(usage.contains("BlackHole"))
            XCTAssertGreaterThan(usage.count, 50)
        }
    }

    /// Run through normal `swift test` / CI so adding copy cannot silently
    /// introduce an untranslated literal lookup in a later redesign.
    func testEveryLiteralLookupInTheAppHasAResourceEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Sources/AuralinkApp")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        let regex = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(\s*("(?:\\.|[^"\\])*")"#)
        let english = try strings(language: "en")
        var lookups = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                let key = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source[range].utf8), options: .fragmentsAllowed) as? String)
                XCTAssertNotNil(english[key], "\(file.lastPathComponent): \(key)")
                lookups += 1
            }
        }
        XCTAssertGreaterThan(lookups, 300)
    }

    private func strings(language: String) throws -> [String: String] {
        try XCTUnwrap(propertyList(language: language, name: "Localizable", extension: "strings") as? [String: String])
    }

    private func propertyList(language: String, name: String, extension ext: String) throws -> [String: Any] {
        let url = try XCTUnwrap(L10n.bundle(for: language).url(forResource: name, withExtension: ext))
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func placeholders(_ value: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+0 #]*\d*(?:\.\d+)?(ll|l|h)?([@diufseEgG])"#)
        var nextPosition = 1
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
            }
            let explicit = group(1)
            let position = explicit.isEmpty ? String(nextPosition) : explicit
            nextPosition += 1
            return position + ":" + group(2) + group(3)
        }.sorted()
    }
}
