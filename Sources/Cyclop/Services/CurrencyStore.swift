import AppKit
import Foundation

/// Exchange rates read from local JSON files. Cyclop never downloads rates.
@MainActor
final class CurrencyStore: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
        var displayCode: String { code.uppercased() }
    }

    /// Which amount field last drove the pair — typing on one side must not
    /// bounce back through the other and fight the caret.
    enum Side { case source, target }

    @Published private(set) var currencies: [Currency] = []
    /// Rates for `rateBase`, keyed by lowercase code: one unit of the base
    /// buys this many of the key.
    @Published private(set) var rates: [String: Double] = [:]
    @Published private(set) var rateBase = ""
    @Published private(set) var rateDate: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    @Published var sourceCode: String {
        didSet {
            guard sourceCode != oldValue else { return }
            persistPair()
            rates = [:]
            rateBase = ""
            rateDate = nil
            Task { await refreshRates() }
            if !suppressSideEffects { recompute(from: .source) }
        }
    }

    @Published var targetCode: String {
        didSet {
            guard targetCode != oldValue else { return }
            persistPair()
            if !suppressSideEffects { recompute(from: .source) }
        }
    }

    @Published var sourceText = "1"
    @Published var targetText = ""

    private var editing: Side = .source
    /// Quiet while both ends of a swap are rewritten, so the intermediate
    /// equal-codes moment never fires a convert against the wrong rate table.
    private var suppressSideEffects = false
    private let defaults = UserDefaults.standard
    private let sourceKey = "currency.source"
    private let targetKey = "currency.target"
    private static var ratesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop/currency-rates", isDirectory: true)
    }

    init() {
        let savedSource = defaults.string(forKey: sourceKey)?.lowercased()
        let savedTarget = defaults.string(forKey: targetKey)?.lowercased()
        sourceCode = savedSource ?? Self.defaultSource
        targetCode = savedTarget ?? Self.defaultTarget
        if sourceCode == targetCode {
            targetCode = sourceCode == "usd" ? "eur" : "usd"
        }
    }

    /// USD out, and the Mac's own currency in — or RUB when the locale has no
    /// currency of its own worth converting against.
    private static var defaultSource: String { "usd" }
    private static var defaultTarget: String {
        let code = Locale.current.currency?.identifier.lowercased()
        if let code, code != "usd", !code.isEmpty { return code }
        return "rub"
    }

    // MARK: - Lifecycle

    func start() {
        Task { await bootstrap() }
    }

    func refreshIfNeeded() {
        Task { await bootstrap() }
    }

    // MARK: - Amounts

    func setSourceText(_ text: String) {
        editing = .source
        sourceText = text
        recompute(from: .source)
    }

    func setTargetText(_ text: String) {
        editing = .target
        targetText = text
        recompute(from: .target)
    }

    func swap() {
        let previousSource = sourceCode
        let previousSourceText = sourceText
        suppressSideEffects = true
        sourceCode = targetCode
        targetCode = previousSource
        suppressSideEffects = false
        // Keep the figure that was typed; the other side follows once rates
        // for the new source land. If they are already cached, recompute now.
        sourceText = previousSourceText
        editing = .source
        if rateBase == sourceCode {
            recompute(from: .source)
        }
    }

    func filtered(query: String) -> [Currency] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return currencies }
        return currencies.filter {
            $0.code.contains(q) || $0.name.lowercased().contains(q)
        }
    }

    func name(for code: String) -> String {
        currencies.first { $0.code == code }?.name ?? code.uppercased()
    }

    // MARK: - Local rates

    private func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        loadCurrencies()
        await refreshRates()
    }

    private func refreshRates() async {
        do {
            if currencies.isEmpty { loadCurrencies() }
            try loadRates(for: sourceCode)
            failure = nil
            recompute(from: editing)
        } catch {
            rates = [:]
            rateBase = ""
            rateDate = nil
            failure = localized("Offline rates are missing or invalid: %@", Self.ratesDirectory.path)
        }
    }
    private func loadCurrencies() {
        let codes = Set(Locale.Currency.isoCurrencies.map { $0.identifier.lowercased() }).union(["btc", "eth", "usdt"])
        let cryptoNames = ["btc": "Bitcoin", "eth": "Ethereum", "usdt": "Tether"]
        currencies = codes.map { code in
            Currency(
                code: code,
                name: cryptoNames[code] ?? Locale.current.localizedString(forCurrencyCode: code.uppercased()) ?? code.uppercased()
            )
        }.sorted {
            let a = Self.pinboard.firstIndex(of: $0.code)
            let b = Self.pinboard.firstIndex(of: $1.code)
            if let a, let b { return a < b }
            if a != nil { return true }
            if b != nil { return false }
            return $0.code < $1.code
        }
        if !currencies.contains(where: { $0.code == sourceCode }) { sourceCode = "usd" }
        if !currencies.contains(where: { $0.code == targetCode }) { targetCode = "eur" }
    }

    private func loadRates(for base: String) throws {
        let code = base.lowercased()
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw URLError(.badURL)
        }
        let url = Self.ratesDirectory
            .appendingPathComponent("currencies", isDirectory: true)
            .appendingPathComponent("\(code).min.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let date = object?["date"] as? String
        let table = object?[code] as? [String: Any] ?? [:]
        var parsed: [String: Double] = [code: 1]
        for (key, value) in table {
            if let number = value as? Double {
                parsed[key.lowercased()] = number
            } else if let number = value as? NSNumber {
                parsed[key.lowercased()] = number.doubleValue
            }
        }
        rates = parsed
        rateBase = code
        rateDate = date
    }

    // MARK: - Conversion

    private func recompute(from side: Side) {
        // Rates belong to a specific base. Stale tables from the previous
        // source must not invent a conversion.
        guard rateBase == sourceCode.lowercased(),
              let rate = rates[targetCode.lowercased()], rate > 0 else {
            return
        }
        switch side {
        case .source:
            let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                targetText = ""
                return
            }
            guard let amount = Self.parse(sourceText) else { return }
            targetText = Self.format(amount * rate)
        case .target:
            let trimmed = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                sourceText = ""
                return
            }
            guard let amount = Self.parse(targetText) else { return }
            sourceText = Self.format(amount / rate)
        }
    }

    private func persistPair() {
        defaults.set(sourceCode, forKey: sourceKey)
        defaults.set(targetCode, forKey: targetKey)
    }

    /// Currencies people actually reach for, pinned to the top of the picker.
    private static let pinboard: [String] = [
        "usd", "eur", "rub", "gbp", "cny", "jpy", "chf", "try", "kzt", "uah",
        "byn", "pln", "aed", "btc", "eth", "usdt",
    ]

    /// Accepts both "1 234,56" and "1234.56". Empty and lone separators are
    /// not numbers — the other field stays put so a mid-edit "1." does not
    /// wipe the result.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains(","), normalized.contains(".") {
            // "1,234.56" vs "1.234,56" — the rightmost separator is decimal.
            if let lastComma = normalized.lastIndex(of: ","),
               let lastDot = normalized.lastIndex(of: ".") {
                if lastComma > lastDot {
                    normalized = normalized.replacingOccurrences(of: ".", with: "")
                    normalized = normalized.replacingOccurrences(of: ",", with: ".")
                } else {
                    normalized = normalized.replacingOccurrences(of: ",", with: "")
                }
            }
        } else {
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// Compact enough for the panel: whole numbers stay whole, fiat keeps a
    /// couple of decimals, tiny crypto rates keep more.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let abs = abs(value)
        let fraction: Int
        if abs >= 1000 { fraction = 2 }
        else if abs >= 1 { fraction = 2 }
        else if abs >= 0.01 { fraction = 4 }
        else if abs >= 0.0001 { fraction = 6 }
        else { fraction = 8 }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fraction
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
