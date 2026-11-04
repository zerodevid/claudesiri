import Foundation

// MARK: - Kurs

/// Kurs: 1 unit mata uang = X USD. Fiat dari open.er-api.com, crypto dari CoinGecko. Cache di UserDefaults.
@MainActor
final class Rates: ObservableObject {
    static let shared = Rates()
    @Published private(set) var usdPer: [String: Double] = ["USD": 1]
    @Published private(set) var updated: Date?
    private var loading = false

    nonisolated static let crypto: [String: String] = [
        "BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "BNB": "binancecoin",
        "USDT": "tether", "USDC": "usd-coin", "HYPE": "hyperliquid", "XRP": "ripple",
        "DOGE": "dogecoin", "TON": "the-open-network", "ADA": "cardano", "TRX": "tron",
    ]

    init() {
        let d = UserDefaults.standard
        if let m = d.dictionary(forKey: "rates") as? [String: Double] { usdPer.merge(m) { $1 } }
        updated = d.object(forKey: "ratesUpdated") as? Date
    }

    func refreshIfStale(maxAge: TimeInterval = 1800) {
        if let u = updated, Date().timeIntervalSince(u) < maxAge, usdPer["IDR"] != nil { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            var fresh: [String: Double] = [:]
            if let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = obj["rates"] as? [String: Double] {
                for (k, v) in rates where v > 0 { fresh[k] = 1 / v }
            }
            let ids = Self.crypto.values.joined(separator: ",")
            if let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] {
                for (sym, id) in Self.crypto { if let p = obj[id]?["usd"] { fresh[sym] = p } }
            }
            await MainActor.run {
                self.loading = false
                guard !fresh.isEmpty else { return }
                self.usdPer.merge(fresh) { $1 }
                self.updated = Date()
                UserDefaults.standard.set(self.usdPer, forKey: "rates")
                UserDefaults.standard.set(self.updated, forKey: "ratesUpdated")
            }
        }
    }

    func convert(_ v: Double, from: String, to: String) -> Double? {
        if from == to { return v }
        guard let a = usdPer[from], let b = usdPer[to] else { return nil }
        return v * a / b
    }
}

// MARK: - Hasil

struct CalcResult: Equatable {
    var expression: String   // baris abu-abu: "200 USD − Rp 1.000.000 ="
    var value: String        // angka besar
    var copyText: String     // yang disalin
    var secondary: String?   // "≈ US$ 138,52"
    var note: String?        // "1 USD = Rp 16.250 · kurs 12.03"
}

// MARK: - Parser

@MainActor
enum Calculator {
    static let home = "IDR"

    private enum Tok: Equatable { case num(Double), cur(String), op(Character), lp, rp, pct, to }

    private struct Val { var v: Double; var cur: String?; var pct = false }

    private struct Fail: Error {}

    static let currencyWords: [String: String] = [
        "rp": "IDR", "idr": "IDR", "rupiah": "IDR",
        "usd": "USD", "dolar": "USD", "dollar": "USD", "dollars": "USD", "us$": "USD",
        "eur": "EUR", "euro": "EUR", "gbp": "GBP", "pound": "GBP", "jpy": "JPY", "yen": "JPY",
        "sgd": "SGD", "myr": "MYR", "ringgit": "MYR", "aud": "AUD", "cny": "CNY", "yuan": "CNY",
        "rmb": "CNY", "krw": "KRW", "won": "KRW", "thb": "THB", "baht": "THB", "hkd": "HKD",
        "sar": "SAR", "riyal": "SAR", "aed": "AED", "dirham": "AED", "chf": "CHF", "cad": "CAD",
        "inr": "INR", "rupee": "INR", "php": "PHP", "peso": "PHP", "vnd": "VND", "twd": "TWD",
        "nzd": "NZD", "try": "TRY", "rub": "RUB", "brl": "BRL", "mxn": "MXN", "kwd": "KWD",
        "qar": "QAR", "egp": "EGP", "pkr": "PKR", "bdt": "BDT", "zar": "ZAR",
        "btc": "BTC", "bitcoin": "BTC", "eth": "ETH", "ethereum": "ETH", "sol": "SOL", "solana": "SOL",
        "bnb": "BNB", "usdt": "USDT", "usdc": "USDC", "hype": "HYPE", "xrp": "XRP",
        "doge": "DOGE", "ton": "TON", "ada": "ADA", "trx": "TRX",
    ]
    static let symbols: [Character: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₩": "KRW", "₹": "INR"]
    static let multipliers: [String: Double] = [
        "k": 1e3, "rb": 1e3, "ribu": 1e3, "jt": 1e6, "juta": 1e6, "mio": 1e6,
        "m": 1e6, "mn": 1e6, "miliar": 1e9, "milyar": 1e9, "b": 1e9, "bn": 1e9, "t": 1e12, "triliun": 1e12,
    ]
    static let toWords: Set<String> = ["ke", "to", "in", "dalam", "jadi", "into"]

    @MainActor
    static func evaluate(_ input: String, rates: Rates = .shared) -> CalcResult? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count < 120, let u = UnitCalc.evaluate(raw) { return u }
        guard !raw.isEmpty, raw.count < 200, var toks = try? tokenize(raw, known: Set(rates.usdPer.keys)) else { return nil }
        if toks.first == .op("=") { toks.removeFirst() }
        while toks.last == .op("=") { toks.removeLast() }

        let hasNum = toks.contains { if case .num = $0 { return true }; return false }
        let hasCur = toks.contains { if case .cur = $0 { return true }; return false }
        let hasOp = toks.contains { if case .op(let o) = $0 { return o != "=" }; return $0 == .pct }
        guard hasNum, hasCur || hasOp else { return nil }

        var target: String?
        // "… ke idr" / "… = idr"
        if toks.count >= 2, case .cur(let c) = toks[toks.count - 1],
           toks[toks.count - 2] == .to || toks[toks.count - 2] == .op("=") {
            target = c; toks.removeLast(2)
        }
        var used = Set<String>()
        var value: Val
        do {
            value = try parse(toks, rates: rates, used: &used)
        } catch {
            // "200 usd idr" → mata uang terakhir = target
            guard target == nil, case .cur(let c) = toks.last else { return nil }
            target = c
            toks.removeLast()
            guard let v = try? parse(toks, rates: rates, used: &used) else { return nil }
            value = v
        }
        if value.pct { value.v /= 100; value.pct = false }
        guard value.v.isFinite else { return nil }

        var pretty = prettyExpression(raw)
        if target != nil {
            let re = #"\s*(ke|to|in|into|dalam|jadi|=|->|→)?\s*[a-zA-Z$€£¥]+\s*[=?]*\s*$"#
            if let r = raw.range(of: re, options: [.regularExpression, .caseInsensitive]) {
                pretty = prettyExpression(String(raw[..<r.lowerBound]))
            }
        }
        guard let cur = value.cur else {
            let s = formatNumber(value.v)
            return CalcResult(expression: pretty + " =", value: s, copyText: s)
        }

        // Tanpa tujuan eksplisit: tidak dikonversi. Satu mata uang tanpa operasi = tidak ada yang dihitung.
        // Campuran mata uang ("200 usd - 1jt idr") → hasil dalam mata uang yang disebut terakhir.
        var lastCur: String?
        for t in toks { if case .cur(let c) = t { lastCur = c } }
        if target == nil && used.count <= 1 && !hasOp { return nil }
        let tgt = target ?? (used.count > 1 ? (lastCur ?? cur) : cur)
        guard let out = rates.convert(value.v, from: cur, to: tgt) else {
            let s = formatMoney(value.v, cur)
            return CalcResult(expression: pretty + " =", value: s, copyText: s,
                              note: "Kurs \(cur)→\(tgt) belum ada (memuat…)")
        }
        let main = formatMoney(out, tgt)
        var secondary: String?
        if cur != tgt && (hasOp || used.count > 1) { secondary = "≈ " + formatMoney(value.v, cur) }

        // catatan kurs: tiap mata uang lain dinyatakan dalam target
        let others = used.union([cur]).subtracting([tgt]).sorted()
        var notes = others.prefix(3).compactMap { c -> String? in
            guard let r = rates.convert(1, from: c, to: tgt) else { return nil }
            if r < 0.01, let inv = rates.convert(1, from: tgt, to: c) {   // mis. IDR→USD: tampilkan 1 USD = Rp…
                return "1 \(tgt) = \(formatMoney(inv, c, precise: true))"
            }
            return "1 \(c) = \(formatMoney(r, tgt, precise: true))"
        }
        if !notes.isEmpty, let u = rates.updated {
            let f = DateFormatter(); f.locale = Locale(identifier: "id_ID")
            f.dateFormat = Calendar.current.isDateInToday(u) ? "HH.mm" : "d MMM HH.mm"
            notes.append("kurs \(f.string(from: u))")
        }
        let head = cur == tgt ? pretty + " =" : (target != nil || !hasOp ? pretty + " → " + tgt : pretty + " ≈")
        return CalcResult(expression: head,
                          value: main, copyText: plainNumber(out, tgt),
                          secondary: secondary, note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: tokenizer

    private static func tokenize(_ s: String, known: Set<String>) throws -> [Tok] {
        let chars = Array(s.lowercased())
        var i = 0
        var out: [Tok] = []
        func peekWord(from j: Int) -> (String, Int) {
            var k = j
            while k < chars.count, chars[k] == " " { k += 1 }
            let start = k
            while k < chars.count, chars[k].isLetter || chars[k] == "$" { k += 1 }
            return (String(chars[start..<k]), k)
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || ((c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," { j += 1 }
                var lit = String(chars[i..<j])
                while let l = lit.last, l == "." || l == "," { lit.removeLast(); j -= 1 }
                guard var n = parseNumber(lit) else { throw Fail() }
                i = j
                let (w, k) = peekWord(from: i)
                if let m = multipliers[w] { n *= m; i = k }
                out.append(.num(n))
                continue
            }
            if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j] == "$" { j += 1 }
                let w = String(chars[i..<j])
                i = j
                if let cur = currencyWords[w] { out.append(.cur(cur)) }
                else if toWords.contains(w) { out.append(.to) }
                else if w == "x" { out.append(.op("*")) }
                else if w.count == 3, known.contains(w.uppercased()) { out.append(.cur(w.uppercased())) } // kode ISO lain
                else { throw Fail() }
                continue
            }
            if let cur = symbols[c] { out.append(.cur(cur)); i += 1; continue }
            switch c {
            case "+": out.append(.op("+"))
            case "-", "−", "–":
                if i + 1 < chars.count, chars[i + 1] == ">" { out.append(.to); i += 1 } else { out.append(.op("-")) }
            case "*", "×", "·": out.append(.op("*"))
            case "/", "÷", ":": out.append(.op("/"))
            case "^": out.append(.op("^"))
            case "=": out.append(.op("="))
            case "→": out.append(.to)
            case "(": out.append(.lp)
            case ")": out.append(.rp)
            case "%": out.append(.pct)
            case "?": break
            default: throw Fail()
            }
            i += 1
        }
        return out
    }

    /// Angka gaya Indonesia & internasional: "6.000.000", "2,5", "1,025", "1,000,000.5", "200.5".
    static func parseNumber(_ lit: String) -> Double? {
        var s = lit
        let dots = s.filter { $0 == "." }.count, commas = s.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            let lastDot = s.lastIndex(of: ".")!, lastComma = s.lastIndex(of: ",")!
            if lastComma > lastDot { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else if commas > 1 {
            s = s.replacingOccurrences(of: ",", with: "")
        } else if commas == 1 {
            s = s.replacingOccurrences(of: ",", with: ".")
        } else if dots > 1 {
            s = s.replacingOccurrences(of: ".", with: "")
        } else if dots == 1 {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            if parts[1].count == 3 && !parts[0].isEmpty && parts[0] != "0" { s = s.replacingOccurrences(of: ".", with: "") }
        }
        return Double(s)
    }

    // MARK: parser (recursive descent)

    private static func parse(_ toks: [Tok], rates: Rates, used: inout Set<String>) throws -> Val {
        var p = 0
        var usedLocal = used
        defer { used = usedLocal }

        func peek() -> Tok? { p < toks.count ? toks[p] : nil }

        func conv(_ b: Val, to cur: String?) throws -> Double {
            guard let bc = b.cur, let c = cur, bc != c else { return b.v }
            guard let r = rates.convert(b.v, from: bc, to: c) else { throw Fail() }
            return r
        }
        func scalar(_ x: Val) -> Double { x.pct ? x.v / 100 : x.v }

        func expr() throws -> Val {
            var a = try term()
            while case .op(let o) = peek(), o == "+" || o == "-" {
                p += 1
                let b = try term()
                if b.pct && !a.pct {
                    a.v = o == "+" ? a.v * (1 + b.v / 100) : a.v * (1 - b.v / 100)
                } else {
                    let cur = a.cur ?? b.cur
                    let av = a.cur == nil ? a.v : a.v
                    let bv = try conv(b, to: cur)
                    a = Val(v: o == "+" ? av + bv : av - bv, cur: cur, pct: a.pct && b.pct)
                }
            }
            return a
        }
        func term() throws -> Val {
            var a = try power()
            while true {
                if case .op(let o) = peek(), o == "*" || o == "/" {
                    p += 1
                    let b = try power()
                    if o == "*" {
                        a = Val(v: scalar(a) * scalar(b), cur: a.cur ?? b.cur)
                    } else if a.cur != nil, b.cur != nil {
                        let bv = try conv(b, to: a.cur)
                        guard bv != 0 else { throw Fail() }
                        a = Val(v: a.v / bv, cur: nil)  // rasio
                    } else {
                        guard scalar(b) != 0 else { throw Fail() }
                        a = Val(v: scalar(a) / scalar(b), cur: a.cur)
                    }
                } else if case .lp = peek() {   // perkalian implisit: 2(3+4)
                    let b = try power()
                    a = Val(v: scalar(a) * scalar(b), cur: a.cur ?? b.cur)
                } else { break }
            }
            return a
        }
        func power() throws -> Val {
            let a = try unary()
            if case .op("^") = peek() {
                p += 1
                let b = try power()
                guard b.cur == nil else { throw Fail() }
                return Val(v: pow(scalar(a), scalar(b)), cur: a.cur)
            }
            return a
        }
        func unary() throws -> Val {
            if case .op("-") = peek() { p += 1; var v = try unary(); v.v = -v.v; return v }
            if case .op("+") = peek() { p += 1; return try unary() }
            return try postfix()
        }
        func postfix() throws -> Val {
            var prefixCur: String?
            if case .cur(let c) = peek() { prefixCur = c; p += 1 }
            var v: Val
            switch peek() {
            case .num(let n): p += 1; v = Val(v: n, cur: nil)
            case .lp:
                p += 1
                v = try expr()
                guard peek() == .rp else { throw Fail() }
                p += 1
            default: throw Fail()
            }
            if peek() == .pct { p += 1; v.pct = true }
            if case .cur(let c) = peek(), prefixCur == nil, v.cur == nil {
                // "200 usd" (tapi bukan "200 usd idr" → yang kedua jadi target)
                p += 1; v.cur = c
            } else if let c = prefixCur {
                if v.cur == nil { v.cur = c } else { v.v = try conv(v, to: c); v.cur = c }
            }
            if let c = v.cur { usedLocal.insert(c) }
            return v
        }

        let v = try expr()
        guard p == toks.count else { throw Fail() }
        return v
    }

    // MARK: format

    static func formatNumber(_ x: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.numberStyle = .decimal
        if x != 0 && abs(x) < 0.0001 {
            f.usesSignificantDigits = true; f.maximumSignificantDigits = 6
        } else {
            f.maximumFractionDigits = abs(x) >= 1e12 ? 0 : 4
        }
        return f.string(from: NSNumber(value: x)) ?? "\(x)"
    }

    static func formatMoney(_ x: Double, _ cur: String, precise: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "id_ID")
        if Rates.crypto[cur] != nil {
            f.numberStyle = .decimal
            if abs(x) >= 1 { f.maximumFractionDigits = 6 } else { f.usesSignificantDigits = true; f.maximumSignificantDigits = 6 }
            return (f.string(from: NSNumber(value: x)) ?? "\(x)") + " " + cur
        }
        f.numberStyle = .currency
        f.currencyCode = cur
        if cur == "IDR" || cur == "JPY" || cur == "KRW" || cur == "VND" {
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = (precise || abs(x) < 100) ? 2 : 0
        } else {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = precise ? 4 : 2
        }
        return f.string(from: NSNumber(value: x)) ?? "\(x) \(cur)"
    }

    /// Angka polos buat disalin: "3254123" / "138.52".
    static func plainNumber(_ x: Double, _ cur: String) -> String {
        let digits = Rates.crypto[cur] != nil ? 8 : (cur == "IDR" ? 0 : 2)
        var s = String(format: "%.\(digits)f", x)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }

    static func prettyExpression(_ s: String) -> String {
        var t = s
        for (a, b) in [("*", "×"), ("/", "÷"), (" x ", " × "), ("-", "−")] { t = t.replacingOccurrences(of: a, with: b) }
        for code in Set(currencyWords.values) {
            t = t.replacingOccurrences(of: "\\b\(code)\\b", with: code, options: [.regularExpression, .caseInsensitive])
        }
        return t
    }
}
