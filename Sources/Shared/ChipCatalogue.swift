import Foundation

// Chip identity and the read-only sensor catalogue, shared by the app (display, passive
// verification) and the privileged helper (its own trusted temperature reads for the fan
// layer). No hardware access here; pure data and parsing. Fingerprinted with the fan
// layer in scripts/check-next23-ui-boundary.sh because the helper's temperature map
// depends on it.

/// The Apple chip parsed once from `machdep.cpu.brand_string`. Everything that
/// needs to know "which chip is this" asks this type instead of matching brand
/// prefixes. An unparseable brand stays nil and degrades to "Unknown chip".
struct ChipIdentity: Sendable, Equatable, Hashable {
    enum Family: String, Sendable {
        /// Mac chips: M1, M2 Pro, M4 Max…
        case m = "M"
        /// iPhone-class chips used in Macs (A18 Pro).
        case a = "A"
    }

    enum Variant: String, Sendable {
        case base = ""
        case pro = "Pro"
        case max = "Max"
        case ultra = "Ultra"
    }

    let family: Family
    let generation: Int
    let variant: Variant

    init(family: Family, generation: Int, variant: Variant) {
        self.family = family
        self.generation = generation
        self.variant = variant
    }

    /// "Apple M2 Max" → M, 2, Max. "Apple A18 Pro" → A, 18, Pro. A suffix Helios does not
    /// know ("Apple M7 Hyper") or a malformed number ("Apple M10x") is nil, so a new chip is
    /// never mistaken for an old one ("Apple M10" is never M1).
    init?(brand: String) {
        guard brand.hasPrefix("Apple ") else { return nil }
        let rest = brand.dropFirst("Apple ".count)
        guard let letter = rest.first, let family = Family(rawValue: String(letter)) else { return nil }
        let afterLetter = rest.dropFirst()
        let digits = afterLetter.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 2, digits.first != "0", let generation = Int(digits)
        else { return nil }
        let suffix = afterLetter.dropFirst(digits.count)
        let variant: Variant
        if suffix.isEmpty {
            variant = .base
        } else {
            guard suffix.first == " ", let parsed = Variant(rawValue: String(suffix.dropFirst())),
                parsed != .base
            else { return nil }
            variant = parsed
        }
        self.init(family: family, generation: generation, variant: variant)
    }

    /// "M4", "M2 Max", "A18 Pro".
    var name: String {
        let base = "\(family.rawValue)\(generation)"
        return variant == .base ? base : "\(base) \(variant.rawValue)"
    }

    var isM4Family: Bool { family == .m && generation == 4 }
}

/// Read-only key → group catalogue per chip family. Exact keys only; a prefix is never trusted.
///
/// Built 2026-10-14 from three independent sources, cross-checked key by key
/// (docs/local/MAPA_CIPU_0_3_0.md): the MIT-licensed Stats catalogue (master), smctemp (GPL,
/// key names only) and iSMC's Apple key descriptions (GPL, key names only), plus user reports
/// in Stats #1703. A key whose role the sources disagree on is left out; a key only one
/// source names stays in. Keys a Mac does not have are simply never read, so one family map
/// covers Pro/Max/Ultra (Ultra's second die keys only exist there). The same key can still
/// mean something else on another variant (cores 5–8 of an M2 Max are E-cores on a base
/// M2), which is why `SensorMapVerifier` confirms groups and drops keys that do not follow
/// their group's load on this Mac. Only the M4 map is physically validated.
enum SensorCatalogue {
    enum Source: String, Sendable {
        /// Physically validated on Mac16,1 (M4). `FanLayerTrustedThermals` serves it to the helper.
        case validated
        /// Cross-checked public catalogues, unverified by Helios on real hardware.
        case catalogue
    }

    struct Map: Sendable, Equatable {
        let performance: Set<String>
        let efficiency: Set<String>
        let gpu: Set<String>
        let source: Source
        /// Where the keys come from, for the sensor-map detail and reports.
        var provenance: String = ""

        /// Non-empty groups in P, E, GPU order: what the helper must read.
        var groups: [Set<String>] { [performance, efficiency, gpu].filter { !$0.isEmpty } }
    }

    /// Bump when any map changes, so evidence gathered for an older map is not reused.
    static let version = 2

    // Exact M4-family thermal-zone mappings derived from the MIT-licensed Stats sensor
    // catalogue and physically validated on Mac16,1. Unchanged: the helper mirrors it.
    static let m4 = Map(
        performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        efficiency: ["Te05", "Te09", "Te0H", "Te0S"],
        gpu: ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k"],
        source: .validated,
        provenance: "Stats, iSMC; validated on Mac16,1")

    /// M5/M6 "super" cores are folded into the performance group.
    private static let mSeries: [Int: Map] = [
        // Stats, smctemp and iSMC agree on cores 1–8 and E 1–2. Ultra's second die (P 9–16,
        // E 3–4) and GPU clusters 5–8 from iSMC; Tg1b/Tg4b seen at runtime on an M1 mini (smctemp).
        1: Map(
            performance: [
                "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                "Tp21", "Tp25", "Tp2D", "Tp2H", "Tp2L", "Tp2P", "Tp2X", "Tp2b",
            ],
            efficiency: ["Tp09", "Tp0T", "Tp29", "Tp2T"],
            gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0b", "Tg0j", "Tg0r", "Tg0z", "Tg1b", "Tg4b"],
            source: .catalogue, provenance: "Stats, smctemp, iSMC"),
        // P: Stats + smctemp/iSMC cores 7–8. On a base M2 (4 P) the upper core keys may be
        // E-cores; per-key verification drops them there. E: Stats + smctemp cores, iSMC E
        // cluster aggregate. GPU: Stats + iSMC clusters.
        2: Map(
            performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r"],
            efficiency: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Te05"],
            gpu: ["Tg0f", "Tg0j", "Tg0n", "Tg0r", "Tg0X", "Tg1h", "Tg1l", "Tg2X", "Tg2f", "Tg3Z"],
            source: .catalogue, provenance: "Stats, smctemp, iSMC"),
        // Corrected 2026-10-14. Stats listed Tf04…Tf4E as P-cores, but iSMC names every Tf key
        // a GPU fabric block and a base M3 has no Tf keys at all (Stats #1703), so the CPU
        // temperature never showed there. Disputed Tf keys are out; the agreed GPU-fabric ones
        // stay GPU. P: base-M3 report (Tp01…Tp0b) + iSMC cores 5–9. E: Te05/Te0L agreed by
        // all; Te0P disputed and left out; iSMC cores 2, 3, 4, 5.
        3: Map(
            performance: [
                "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                "Tp0h", "Tp0n", "Tp1F", "Tp1R", "Tp0z",
            ],
            efficiency: ["Te05", "Te0L", "Te0H", "Te0Q", "Te0S", "Te0U"],
            gpu: [
                "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A", "Tf9F",
                "Tg05", "Tg0D", "Tg0L", "Tg01", "Tg0u", "Tg0v", "Tg13", "Tg1B", "Tg1l", "Tg0z", "Tg1F",
                "Tg17", "Tg1t", "Tg1y", "Tg22", "Tg0P", "Tg0X", "Tg0b", "Tg0j",
            ],
            source: .catalogue, provenance: "iSMC, Stats #1703 reports, smctemp, Stats"),
        4: m4,
        // All three sources agree. Extra P cores of M5 Pro/Max from iSMC. No E keys are known
        // (a base M5's efficiency cores stay without a temperature until a dump shows them).
        5: Map(
            performance: [
                "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u",
                "Tp0y", "Tp1E", "Tp1I", "Tp1Q", "Tp1U", "Tp1g",
            ],
            efficiency: [],
            gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
            source: .catalogue, provenance: "Stats, smctemp, iSMC"),
        // Stats only.
        6: Map(
            performance: [
                "Tp0j", "Tp0g", "Tp09", "Tp07",
                "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05",
            ],
            efficiency: ["Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
            gpu: [
                "Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g",
                "Tg1h",
            ], source: .catalogue, provenance: "Stats"),
    ]

    /// A18 Pro (MacBook Neo, Mac17,5): Stats and iSMC agree.
    private static let a18Pro = Map(
        performance: ["Tp05", "Tp0D"], efficiency: ["Te05", "Te0S"],
        gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0e"], source: .catalogue, provenance: "Stats, iSMC")

    static func map(for chip: ChipIdentity?) -> Map? {
        guard let chip else { return nil }
        switch chip.family {
        case .m: return mSeries[chip.generation]
        case .a: return chip.generation == 18 && chip.variant == .pro ? a18Pro : nil
        }
    }
}

