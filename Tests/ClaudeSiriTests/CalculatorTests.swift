import XCTest
import Carbon.HIToolbox
@testable import ClaudeSiri

/// Fixed rates so results do not depend on the network: 1 USD = Rp18.000, 1 EUR = 1.10 USD.
@MainActor
private let rates = Rates(fixed: ["USD": 1, "IDR": 1.0 / 18_000, "EUR": 1.10])

@MainActor
final class CalculatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set("id", forKey: "uiLanguage")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "uiLanguage")
        super.tearDown()
    }

    private func value(_ s: String) -> String? { Calculator.evaluate(s, rates: rates)?.value }

    // MARK: arithmetic

    func testBasicArithmetic() {
        XCTAssertEqual(value("1+2"), "3")
        XCTAssertEqual(value("2(3+4)"), "14")
        XCTAssertEqual(value("2^10"), "1.024")
    }

    func testIndonesianMultipliersAndDecimals() {
        XCTAssertEqual(value("1,5 jt / 4"), "375.000")
        XCTAssertEqual(value("(250rb + 1,2jt) * 12"), "17.400.000")
        XCTAssertEqual(value("6.000.000 / 2"), "3.000.000")
    }

    func testPercentLikeAppleCalculator() {
        XCTAssertEqual(value("3jt - 15%"), "2.550.000")
        XCTAssertEqual(value("200 + 10%"), "220")
    }

    func testPlainTextIsNotMath() {
        XCTAssertNil(value("halo apa kabar"))
        XCTAssertNil(value("tulis pesan untuk klien"))
    }

    // MARK: currency

    func testConvertsOnlyWithATarget() {
        XCTAssertNil(value("100 usd"), "a lone amount must not be converted")
        XCTAssertEqual(value("100 usd idr").map(digits), "1800000")
        XCTAssertEqual(value("18000000 idr usd").map(digits), "100000")   // US$1.000,00
        XCTAssertEqual(value("100 usd ke idr").map(digits), "1800000")
    }

    func testMixedCurrenciesUseTheLastOne() {
        // 200 USD = Rp3.600.000, minus Rp1.000.000
        XCTAssertEqual(value("200 usd - 1000000 idr").map(digits), "2600000")
        let r = Calculator.evaluate("200 usd - 1000000 idr", rates: rates)
        XCTAssertNotNil(r?.secondary, "mixed currencies show the result in the other currency too")
    }

    func testCopyTextIsPlain() {
        XCTAssertEqual(Calculator.evaluate("100 usd idr", rates: rates)?.copyText, "1800000")
    }

    func testStaleRatesAreFlagged() {
        let now = Date()
        XCTAssertFalse(Calculator.rateAge(now.addingTimeInterval(-600), now: now).contains("⚠︎"))
        XCTAssertTrue(Calculator.rateAge(now.addingTimeInterval(-3 * 86_400), now: now).contains("⚠︎"))
    }

    // MARK: language

    func testEnglishNumberFormatting() {
        UserDefaults.standard.set("en", forKey: "uiLanguage")
        XCTAssertEqual(value("3jt - 15%"), "2,550,000")
        XCTAssertEqual(value("5 km to mi"), "3.1069 mi")
    }

    // MARK: units

    func testUnits() {
        XCTAssertEqual(value("5 km ke mil"), "3,1069 mil")
        XCTAssertEqual(value("30 c ke f"), "86 °F")
        XCTAssertEqual(value("2 gb ke mb"), "2.000 MB")
        XCTAssertNil(value("5 km ke kg"), "different dimensions do not convert")
    }

    // MARK: dates

    func testDateOffsets() {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let in90 = f.string(from: cal.date(byAdding: .day, value: 90, to: today)!)
        XCTAssertEqual(Calculator.evaluate("90 hari lagi", rates: rates)?.copyText, in90)
        XCTAssertEqual(Calculator.evaluate("in 90 days", rates: rates)?.copyText, in90)
        let ago = f.string(from: cal.date(byAdding: .day, value: -30, to: today)!)
        XCTAssertEqual(Calculator.evaluate("30 days ago", rates: rates)?.copyText, ago)
    }

    func testDaysBetween() {
        XCTAssertEqual(Calculator.evaluate("1/1/2026 sampai 4/11/2026", rates: rates)?.copyText, "307")
    }

    private func digits(_ s: String) -> String { s.filter(\.isNumber) }
}

final class PermissionRuleTests: XCTestCase {
    private func rule(_ cmd: String) -> String? {
        PermissionRules.suggestion(tool: "Bash", input: ["command": cmd])?.rule
    }

    func testNarrowBashRules() {
        XCTAssertEqual(rule("git status"), "Bash(git status:*)")
        XCTAssertEqual(rule("npm run build"), "Bash(npm run:*)")
        XCTAssertEqual(rule("ls -la"), "Bash(ls:*)")
        XCTAssertEqual(rule("git --version"), "Bash(git:*)")
    }

    func testNoRulesForDangerousOrCompoundCommands() {
        XCTAssertNil(rule("rm -rf build"))
        XCTAssertNil(rule("sudo reboot"))
        XCTAssertNil(rule("echo hi && rm x"))
        XCTAssertNil(rule("cat a | grep b"))
        XCTAssertNil(rule("echo $(whoami)"))
        XCTAssertNil(rule("./script.sh"))
    }

    func testFileEditsShareOneRule() {
        for tool in ["Edit", "Write", "MultiEdit"] {
            XCTAssertEqual(PermissionRules.suggestion(tool: tool, input: [:])?.rule, "Edit")
        }
    }
}

final class HotkeyTests: XCTestCase {
    func testDisplay() {
        XCTAssertEqual(Hotkey(code: kVK_Space, mods: optionKey).display, "⌥Space")
        XCTAssertEqual(Hotkey(code: kVK_Space, mods: optionKey).voiceDisplay, "⌥⇧Space")
        XCTAssertEqual(Hotkey(code: kVK_Space, mods: cmdKey | controlKey).display, "⌃⌘Space")
    }
}

final class HistoryContextTests: XCTestCase {
    func testSplitsTheContextBlock() {
        let msg = "<context>Text I have selected in Dia:\n\"\"\"\n0x7583ab…\nsecond line\n\"\"\"</context>\n\ncek address ini"
        let c = History.splitContext(msg)
        XCTAssertEqual(c.app, "Dia")
        XCTAssertEqual(c.selected, "0x7583ab…\nsecond line")
        XCTAssertEqual(c.text, "cek address ini")
    }

    func testReadsOlderIndonesianBlocks() {
        let msg = "<konteks>Teks yang sedang saya pilih di Safari:\n\"\"\"\nhalo\n\"\"\"</konteks>\n\nterjemahkan"
        let c = History.splitContext(msg)
        XCTAssertEqual(c.app, "Safari")
        XCTAssertEqual(c.selected, "halo")
        XCTAssertEqual(c.text, "terjemahkan")
    }

    func testPlainMessagesAreUntouched() {
        let c = History.splitContext("just a question")
        XCTAssertNil(c.app); XCTAssertNil(c.selected)
        XCTAssertEqual(c.text, "just a question")
    }
}
