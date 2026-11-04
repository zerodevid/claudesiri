import Foundation

/// Konversi satuan ("5 km ke mil", "100 f ke c") dan hitungan tanggal
/// ("30 hari lagi", "umur 12/3/1998", "1/1/2026 sampai 4/11/2026").
@MainActor
enum UnitCalc {
    private struct U { let dim: String; let factor: Double; let label: String }

    // faktor ke satuan dasar: meter, kilogram, liter, detik, byte, m², m/s
    private static let units: [String: U] = {
        var u: [String: U] = [:]
        func add(_ names: [String], _ dim: String, _ f: Double, _ label: String) { for n in names { u[n] = U(dim: dim, factor: f, label: label) } }
        add(["mm", "milimeter"], "len", 0.001, "mm")
        add(["cm", "centimeter", "sentimeter", "senti"], "len", 0.01, "cm")
        add(["m", "meter"], "len", 1, "m")
        add(["km", "kilometer", "kilo meter"], "len", 1000, "km")
        add(["in", "inch", "inci", "\""], "len", 0.0254, "in")
        add(["ft", "feet", "foot", "kaki"], "len", 0.3048, "ft")
        add(["yd", "yard"], "len", 0.9144, "yd")
        add(["mi", "mil", "mile", "miles"], "len", 1609.344, "mil")
        add(["nmi", "mil laut"], "len", 1852, "mil laut")
        add(["mg", "miligram"], "mass", 1e-6, "mg")
        add(["g", "gr", "gram"], "mass", 0.001, "g")
        add(["ons"], "mass", 0.1, "ons")
        add(["kg", "kilogram", "kilo"], "mass", 1, "kg")
        add(["kuintal"], "mass", 100, "kuintal")
        add(["ton", "tonne"], "mass", 1000, "ton")
        add(["lb", "lbs", "pound", "pon"], "mass", 0.45359237, "lb")
        add(["oz", "ounce"], "mass", 0.028349523125, "oz")
        add(["ml", "mililiter"], "vol", 0.001, "ml")
        add(["l", "liter", "litre"], "vol", 1, "L")
        add(["gal", "galon", "gallon"], "vol", 3.785411784, "gal")
        add(["cup", "gelas"], "vol", 0.2365882365, "cup")
        add(["floz"], "vol", 0.0295735, "fl oz")
        add(["ms", "milidetik"], "time", 0.001, "ms")
        add(["s", "detik", "dtk", "sec", "second", "seconds"], "time", 1, "detik")
        add(["min", "menit", "minute", "minutes"], "time", 60, "menit")
        add(["h", "jam", "hour", "hours"], "time", 3600, "jam")
        add(["hari", "day", "days"], "time", 86400, "hari")
        add(["minggu", "week", "weeks", "pekan"], "time", 604800, "minggu")
        add(["tahun", "year", "years", "thn"], "time", 31557600, "tahun")
        add(["b", "byte", "bytes"], "data", 1, "B")
        add(["kb"], "data", 1e3, "KB")
        add(["mb"], "data", 1e6, "MB")
        add(["gb"], "data", 1e9, "GB")
        add(["tb"], "data", 1e12, "TB")
        add(["kib"], "data", 1024, "KiB")
        add(["mib"], "data", 1_048_576, "MiB")
        add(["gib"], "data", 1_073_741_824, "GiB")
        add(["m2", "m²", "meter persegi"], "area", 1, "m²")
        add(["km2", "km²"], "area", 1e6, "km²")
        add(["ha", "hektar", "hektare"], "area", 1e4, "ha")
        add(["are"], "area", 100, "are")
        add(["acre", "ekar"], "area", 4046.8564224, "acre")
        add(["ft2", "ft²", "sqft"], "area", 0.09290304, "ft²")
        add(["kmh", "km/h", "km/jam", "kph"], "speed", 1 / 3.6, "km/jam")
        add(["mph"], "speed", 0.44704, "mph")
        add(["m/s", "mps"], "speed", 1, "m/s")
        add(["knot", "kn", "knots"], "speed", 0.514444, "knot")
        return u
    }()

    private static let temps: [String: String] = [
        "c": "C", "°c": "C", "celsius": "C", "celcius": "C",
        "f": "F", "°f": "F", "fahrenheit": "F",
        "k": "K", "kelvin": "K", "r": "R", "reamur": "R", "réaumur": "R",
    ]

    static func evaluate(_ raw: String) -> CalcResult? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return convertUnits(s, raw: raw) ?? dates(s, raw: raw)
    }

    // MARK: satuan

    private static func convertUnits(_ s: String, raw: String) -> CalcResult? {
        let re = #"^(-?[\d.,]+)\s*([a-z°²/"][a-z0-9°²/" ]*?)\s+(?:ke|to|in|jadi|dalam|=|->|→)\s+([a-z°²/"][a-z0-9°²/" ]*?)\s*\??$"#
        guard let m = s.firstMatch(of: try! Regex(re)),
              let numS = m.output[1].substring, let fromS = m.output[2].substring, let toS = m.output[3].substring,
              let n = Calculator.parseNumber(String(numS)) else { return nil }
        let from = String(fromS).trimmingCharacters(in: .whitespaces), to = String(toS).trimmingCharacters(in: .whitespaces)

        if let a = temps[from], let b = temps[to] {
            let c: Double = switch a { case "F": (n - 32) * 5 / 9; case "K": n - 273.15; case "R": n * 5 / 4; default: n }
            let out: Double = switch b { case "F": c * 9 / 5 + 32; case "K": c + 273.15; case "R": c * 4 / 5; default: c }
            let v = Calculator.formatNumber((out * 100).rounded() / 100) + (b == "K" ? " K" : " °\(b)")
            return CalcResult(expression: "\(Calculator.formatNumber(n)) °\(a) → °\(b)".replacingOccurrences(of: "°K", with: "K"),
                              value: v, copyText: String(format: "%.2f", out))
        }
        guard let ua = units[from], let ub = units[to], ua.dim == ub.dim else { return nil }
        let out = n * ua.factor / ub.factor
        return CalcResult(expression: "\(Calculator.formatNumber(n)) \(ua.label) → \(ub.label)",
                          value: Calculator.formatNumber(out) + " " + ub.label,
                          copyText: plain(out),
                          note: "1 \(ua.label) = \(Calculator.formatNumber(ua.factor / ub.factor)) \(ub.label)")
    }

    private static func plain(_ x: Double) -> String {
        var t = String(format: "%.6f", x)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    // MARK: tanggal

    private static let months: [String: Int] = [
        "jan": 1, "januari": 1, "january": 1, "feb": 2, "februari": 2, "february": 2, "mar": 3, "maret": 3, "march": 3,
        "apr": 4, "april": 4, "mei": 5, "may": 5, "jun": 6, "juni": 6, "june": 6, "jul": 7, "juli": 7, "july": 7,
        "agu": 8, "agt": 8, "agustus": 8, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "okt": 10, "oktober": 10, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "des": 12, "desember": 12, "dec": 12, "december": 12,
    ]

    private static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }

    static func parseDate(_ t: String) -> Date? {
        let t = t.trimmingCharacters(in: .whitespaces)
        if ["hari ini", "sekarang", "today", "now"].contains(t) { return cal.startOfDay(for: Date()) }
        if ["besok", "tomorrow"].contains(t) { return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) }
        if ["kemarin", "yesterday"].contains(t) { return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) }
        var d: Int?, mo: Int?, y: Int?
        if let m = t.firstMatch(of: #/^(\d{4})-(\d{1,2})-(\d{1,2})$/#) {
            y = Int(m.1); mo = Int(m.2); d = Int(m.3)
        } else if let m = t.firstMatch(of: #/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})$/#) {
            d = Int(m.1); mo = Int(m.2); y = Int(m.3)
        } else if let m = t.firstMatch(of: #/^(\d{1,2})\s+([a-z]+)\s+(\d{4})$/#), let mm = months[String(m.2)] {
            d = Int(m.1); mo = mm; y = Int(m.3)
        } else if let m = t.firstMatch(of: #/^(\d{1,2})\s+([a-z]+)$/#), let mm = months[String(m.2)] {
            d = Int(m.1); mo = mm; y = cal.component(.year, from: Date())
        }
        guard var yy = y, let mm = mo, let dd = d, (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        if yy < 100 { yy += yy > 50 ? 1900 : 2000 }
        return cal.date(from: DateComponents(year: yy, month: mm, day: dd))
    }

    private static func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "id_ID"); f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: d)
    }

    private static func span(_ a: Date, _ b: Date) -> (String, Int) {
        let (lo, hi) = a < b ? (a, b) : (b, a)
        let c = cal.dateComponents([.year, .month, .day], from: lo, to: hi)
        let days = cal.dateComponents([.day], from: lo, to: hi).day ?? 0
        var parts: [String] = []
        if let y = c.year, y > 0 { parts.append("\(y) tahun") }
        if let m = c.month, m > 0 { parts.append("\(m) bulan") }
        if let d = c.day, d > 0 || parts.isEmpty { parts.append("\(d) hari") }
        return (parts.joined(separator: " "), days)
    }

    private static func dates(_ s: String, raw: String) -> CalcResult? {
        let unitMap: [String: Calendar.Component] = ["hari": .day, "day": .day, "days": .day, "minggu": .weekOfYear, "pekan": .weekOfYear,
                                                     "week": .weekOfYear, "weeks": .weekOfYear, "bulan": .month, "month": .month,
                                                     "months": .month, "tahun": .year, "year": .year, "years": .year]
        // "30 hari lagi", "3 bulan dari sekarang", "100 hari yang lalu", "2 minggu dari 1/12/2026"
        if let m = s.firstMatch(of: #/^(\d+)\s+([a-z]+)\s+(lagi|kemudian|dari sekarang|dari hari ini|ke depan|yang lalu|lalu|sebelumnya|ago|from now|dari .+|sebelum .+)$/#),
           let n = Int(m.1), let comp = unitMap[String(m.2)] {
            let tail = String(m.3)
            var base = cal.startOfDay(for: Date())
            var sign = 1
            if tail.hasPrefix("dari "), !["dari sekarang", "dari hari ini"].contains(tail) {
                guard let b = parseDate(String(tail.dropFirst(5))) else { return nil }; base = b
            } else if tail.hasPrefix("sebelum ") {
                guard let b = parseDate(String(tail.dropFirst(8))) else { return nil }; base = b; sign = -1
            } else if ["yang lalu", "lalu", "sebelumnya", "ago"].contains(tail) { sign = -1 }
            guard let d = cal.date(byAdding: comp, value: sign * n, to: base) else { return nil }
            return CalcResult(expression: raw.trimmingCharacters(in: .whitespaces) + " =", value: fmt(d), copyText: isoDate(d))
        }
        // "umur 12/3/1998", "sejak 1 januari 2020"
        if let m = s.firstMatch(of: #/^(umur|usia|sejak|since|age)\s+(.+)$/#), let d = parseDate(String(m.2)) {
            let (txt, days) = span(d, cal.startOfDay(for: Date()))
            return CalcResult(expression: raw.trimmingCharacters(in: .whitespaces) + " =", value: txt, copyText: txt,
                              secondary: "= \(Calculator.formatNumber(Double(days))) hari", note: "sejak \(fmt(d))")
        }
        // "1/1/2026 sampai 4/11/2026", "hari ini sampai 25 desember"
        if let m = s.firstMatch(of: #/^(?:selisih\s+)?(.+?)\s+(?:sampai|hingga|s\/d|sd|to|until|ke)\s+(.+)$/#),
           let a = parseDate(String(m.1)), let b = parseDate(String(m.2)) {
            let (txt, days) = span(a, b)
            return CalcResult(expression: raw.trimmingCharacters(in: .whitespaces) + " =",
                              value: "\(Calculator.formatNumber(Double(days))) hari", copyText: "\(days)",
                              secondary: "= \(txt)", note: "\(fmt(a)) → \(fmt(b))")
        }
        // "25 desember 2026" / "12/3/1998" → hari apa
        if s.contains(where: \.isNumber), let d = parseDate(s) {
            let (txt, days) = span(cal.startOfDay(for: Date()), d)
            let rel = days == 0 ? "hari ini" : (d > Date() ? "\(txt) lagi" : "\(txt) yang lalu")
            return CalcResult(expression: raw.trimmingCharacters(in: .whitespaces) + " =", value: fmt(d), copyText: isoDate(d),
                              secondary: rel)
        }
        return nil
    }

    private static func isoDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}
