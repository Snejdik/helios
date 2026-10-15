import Foundation

// Chip profiles and passive sensor-map verification (PLAN_0_3_0 M1). Pure fixtures:
// no SMC, no IORegistry, no fan writes.

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw CheckFailure(description: message) }
}

/// One Mac the gate must describe correctly. Expectations, not measurements: only the M4
/// row is physically validated; the rest pin today's catalogue behaviour.
private struct ChipFixture {
  let brand: String
  let model: String
  let performance: Int?
  let efficiency: Int?
  let fans: Int
  let chipName: String?
  let mapSource: SensorCatalogue.Source?
  /// Expected baseline status for P, E and GPU groups.
  let baseline: (SensorMapStatus, SensorMapStatus, SensorMapStatus)
  /// The helper's temperature trust (0.3.0 M2): validated for M4, catalogue elsewhere,
  /// nil for an unknown chip.
  let fanThermals: FanLayerThermalTrust?
}

private let catalogue = (SensorMapStatus.catalogue, SensorMapStatus.catalogue, SensorMapStatus.catalogue)
private let validated = (SensorMapStatus.validated, SensorMapStatus.validated, SensorMapStatus.validated)
private let unknown = (SensorMapStatus.unknown, SensorMapStatus.unknown, SensorMapStatus.unknown)

private let fixtures: [ChipFixture] = [
  ChipFixture(brand: "Apple M1", model: "Macmini9,1", performance: 4, efficiency: 4, fans: 1,
    chipName: "M1", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M1", model: "MacBookAir10,1", performance: 4, efficiency: 4, fans: 0,
    chipName: "M1", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M1 Pro", model: "MacBookPro18,3", performance: 8, efficiency: 2, fans: 2,
    chipName: "M1 Pro", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M1 Max", model: "MacBookPro18,2", performance: 8, efficiency: 2, fans: 2,
    chipName: "M1 Max", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M1 Ultra", model: "Mac13,2", performance: 16, efficiency: 4, fans: 2,
    chipName: "M1 Ultra", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M2", model: "Mac14,2", performance: 4, efficiency: 4, fans: 0,
    chipName: "M2", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M2 Pro", model: "Mac14,9", performance: 6, efficiency: 4, fans: 2,
    chipName: "M2 Pro", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M2 Ultra", model: "Mac14,14", performance: 16, efficiency: 8, fans: 1,
    chipName: "M2 Ultra", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M3", model: "Mac15,3", performance: 4, efficiency: 4, fans: 1,
    chipName: "M3", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M3 Pro", model: "Mac15,6", performance: 5, efficiency: 6, fans: 2,
    chipName: "M3 Pro", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M3 Max", model: "Mac15,8", performance: 12, efficiency: 4, fans: 2,
    chipName: "M3 Max", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple M4", model: "Mac16,1", performance: 4, efficiency: 6, fans: 1,
    chipName: "M4", mapSource: .validated, baseline: validated, fanThermals: .validated),
  ChipFixture(brand: "Apple M4 Pro", model: "Mac16,8", performance: 10, efficiency: 4, fans: 2,
    chipName: "M4 Pro", mapSource: .validated, baseline: validated, fanThermals: .validated),
  ChipFixture(brand: "Apple M4 Max", model: "Mac16,6", performance: 12, efficiency: 4, fans: 2,
    chipName: "M4 Max", mapSource: .validated, baseline: validated, fanThermals: .validated),
  // The catalogue has no efficiency group for M5 (super cores fold into P).
  ChipFixture(brand: "Apple M5", model: "fixture-m5", performance: 4, efficiency: 6, fans: 1,
    chipName: "M5", mapSource: .catalogue, baseline: (.catalogue, .unknown, .catalogue),
    fanThermals: .catalogue),
  ChipFixture(brand: "Apple M6", model: "fixture-m6", performance: 4, efficiency: 6, fans: 1,
    chipName: "M6", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  ChipFixture(brand: "Apple A18 Pro", model: "fixture-a18", performance: 2, efficiency: 4, fans: 0,
    chipName: "A18 Pro", mapSource: .catalogue, baseline: catalogue, fanThermals: .catalogue),
  // Parsable but not catalogued, and never mistaken for an older chip.
  ChipFixture(brand: "Apple M7", model: "fixture-m7", performance: nil, efficiency: nil, fans: 1,
    chipName: "M7", mapSource: nil, baseline: unknown, fanThermals: nil),
  ChipFixture(brand: "Apple M10", model: "fixture-m10", performance: nil, efficiency: nil, fans: 1,
    chipName: "M10", mapSource: nil, baseline: unknown, fanThermals: nil),
  ChipFixture(brand: "Apple A17 Pro", model: "fixture-a17", performance: nil, efficiency: nil, fans: 0,
    chipName: "A17 Pro", mapSource: nil, baseline: unknown, fanThermals: nil),
  // Unparseable: unknown chip, no map, no crash.
  // The helper's old prefix match would have trusted an unknown "M4 Hyper"; the M2 batch
  // moved it onto the same exact parser, so it has no map at all.
  ChipFixture(brand: "Apple M4 Hyper", model: "fixture-x", performance: nil, efficiency: nil, fans: 1,
    chipName: nil, mapSource: nil, baseline: unknown, fanThermals: nil),
  ChipFixture(brand: "Apple M01", model: "fixture-x", performance: nil, efficiency: nil, fans: 1,
    chipName: nil, mapSource: nil, baseline: unknown, fanThermals: nil),
  ChipFixture(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", model: "MacBookPro16,1",
    performance: nil, efficiency: nil, fans: 2, chipName: nil, mapSource: nil, baseline: unknown,
    fanThermals: nil),
  ChipFixture(brand: "", model: "", performance: nil, efficiency: nil, fans: 0,
    chipName: nil, mapSource: nil, baseline: unknown, fanThermals: nil),
]

private func profileChecks() throws {
  for fixture in fixtures {
    let profile = MacProfile(machineModel: fixture.model, osBuild: "26A434", cpuBrand: fixture.brand,
      performanceCoreCount: fixture.performance, efficiencyCoreCount: fixture.efficiency)
    let label = "\(fixture.brand.isEmpty ? "<empty>" : fixture.brand) / \(fixture.model)"
    try require(profile.chip?.name == fixture.chipName, "\(label): chip \(String(describing: profile.chip?.name))")
    try require(profile.sensorMap?.source == fixture.mapSource, "\(label): map source")
    let statuses = (
      profile.baselineStatus(for: .performanceCPU), profile.baselineStatus(for: .efficiencyCPU),
      profile.baselineStatus(for: .gpu))
    try require(statuses == fixture.baseline, "\(label): baseline \(statuses)")
    try require(profile.baselineStatus(for: .unclassified) == .unknown, "\(label): unclassified")
    try require(
      FanLayerTrustedThermals.trust(for: fixture.brand) == fixture.fanThermals,
      "\(label): fan-layer temperature trust drifted from the chip profile")
    try require(!profile.summary.isEmpty, "\(label): summary")
    // The verifier must accept every profile without trapping, even with no map.
    var verifier = SensorMapVerifier(profile: profile)
    verifier.observe(
      ThermalMetrics(readings: [ThermalReading(key: "Tp01", group: .unclassified, celsius: 50)],
        failures: [:]),
      load: .init(performance: 0, efficiency: 0, gpu: 0))
    if fixture.mapSource == nil {
      try require(verifier.statuses.isEmpty, "\(label): unknown chip must not report map statuses")
    }
    _ = fixture.fans
  }

  // Classifier behaviour is unchanged for the validated M4 family and unknown chips.
  let m4 = ThermalClassifier(cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "25G83")
  try require(m4.group(for: "Tp01") == .performanceCPU, "M4 Tp01 trusted P")
  try require(m4.group(for: "Te0S") == .efficiencyCPU, "M4 Te0S trusted E")
  try require(m4.group(for: "Tg1k") == .gpu, "M4 Tg1k trusted GPU")
  try require(m4.group(for: "Te06") == .validatedHotspot, "Mac16,1/25G83 hotspot")
  try require(
    ThermalClassifier(cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "26A434")
      .group(for: "Te06") == .unclassified, "hotspot stays exact-build only")
  try require(ThermalClassifier(cpuBrand: "Apple M4 Pro").group(for: "Tp0e") == .performanceCPU,
    "M4 Pro shares the trusted map")
  try require(ThermalClassifier(cpuBrand: "Apple M40").group(for: "Tp01") == .unclassified,
    "M40 is not M4")
  let m1 = ThermalClassifier(cpuBrand: "Apple M1 Pro")
  try require(m1.group(for: "Tp09") == .unclassified, "catalogue keys are never trusted")
  try require(m1.displayGroup(for: "Tp09") == .efficiencyCPU, "M1 Tp09 is an E-core")
  try require(ThermalClassifier(cpuBrand: "Apple M2").displayGroup(for: "Tp09") == .performanceCPU,
    "M2 Tp09 is a P-core")
  try require(ThermalClassifier(cpuBrand: "Apple A18 Pro").displayGroup(for: "Tg0e") == .gpu,
    "A18 Pro GPU")
  try require(ThermalClassifier(cpuBrand: "Apple A18 Pro").group(for: "Tp05") == .unclassified,
    "A18 Pro is display-only")
  try require(ThermalClassifier.generation(ofCPUBrand: "Apple M2 Max") == 2, "generation M2 Max")
  try require(ThermalClassifier.generation(ofCPUBrand: "Apple A18 Pro") == nil, "generation is M-only")
  try require(ThermalClassifier.generation(ofCPUBrand: "Apple M10") == 10, "M10")

  // The helper's trusted sets mirror the app's validated map exactly.
  try require(SensorCatalogue.m4.performance == FanLayerTrustedThermals.m4PerformanceCPU, "M4 P mirror")
  try require(SensorCatalogue.m4.efficiency == FanLayerTrustedThermals.m4EfficiencyCPU, "M4 E mirror")
  try require(SensorCatalogue.m4.gpu == FanLayerTrustedThermals.m4GPU, "M4 GPU mirror")

  // Catalogue maps never put one key in two groups.
  for brand in ["Apple M1", "Apple M2", "Apple M3", "Apple M4", "Apple M5", "Apple M6", "Apple A18 Pro"] {
    guard let map = SensorCatalogue.map(for: ChipIdentity(brand: brand)) else {
      throw CheckFailure(description: "\(brand): missing catalogue map")
    }
    try require(map.performance.isDisjoint(with: map.efficiency), "\(brand): P/E overlap")
    try require(map.performance.isDisjoint(with: map.gpu), "\(brand): P/GPU overlap")
    try require(map.efficiency.isDisjoint(with: map.gpu), "\(brand): E/GPU overlap")
  }
  // Every known Apple Silicon model: its chip parses, has a map (or an honest unknown),
  // and the helper trusts the validated map only on the M4 family.
  var families = Set<String>()
  for (model, entry) in MacModelCatalogue.entries {
    let profile = MacProfile(machineModel: model, osBuild: "26A434", cpuBrand: "Apple \(entry.chip)")
    guard let chip = profile.chip else { throw CheckFailure(description: "\(model): chip \(entry.chip) does not parse") }
    try require(chip.name == entry.chip, "\(model): chip name")
    try require(profile.sensorMap != nil, "\(model): no sensor map for \(entry.chip)")
    try require(profile.summary.hasPrefix(entry.name), "\(model): summary uses the model name")
    try require(!entry.name.isEmpty && entry.name.contains(entry.chip), "\(model): name mentions its chip")
    if entry.name.hasPrefix("MacBook Air") { try require(entry.fans == 0, "\(model): Airs are fanless") }
    if entry.name.hasPrefix("MacBook Pro"), chip.variant != .base {
      try require(entry.fans == 2, "\(model): Pro/Max MacBook Pros have two fans")
    }
    try require(FanLayerTrustedThermals.trust(for: "Apple \(entry.chip)") == (chip.isM4Family ? .validated : .catalogue),
      "\(model): fan-layer trust")
    families.insert("\(chip.family.rawValue)\(chip.generation)")
  }
  try require(families == ["M1", "M2", "M3", "M4", "M5", "M6", "A18"], "model families \(families.sorted())")
  try require(MacModelCatalogue.entries.count >= 59, "model table complete")
  let mac161 = MacProfile(machineModel: "Mac16,1", osBuild: "26A434", cpuBrand: "Apple M4",
    performanceCoreCount: 4, efficiencyCoreCount: 6)
  try require(mac161.summary == "MacBook Pro 14″ (M4, 2024) · 4 P + 6 E cores", "summary \(mac161.summary)")

  // Corrected M3 map: no disputed Tf key is shown as a CPU core.
  let m3 = ThermalClassifier(cpuBrand: "Apple M3 Max")
  for key in ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E", "Te0P"] {
    try require(m3.displayGroup(for: key) == .unclassified, "M3 disputed \(key) left out")
  }
  try require(m3.displayGroup(for: "Tp01") == .performanceCPU && m3.displayGroup(for: "Te0L") == .efficiencyCPU
    && m3.displayGroup(for: "Tf14") == .gpu, "M3 corrected groups")
  let m1u = ThermalClassifier(cpuBrand: "Apple M1 Ultra")
  try require(m1u.displayGroup(for: "Tp2b") == .performanceCPU && m1u.displayGroup(for: "Tp2T") == .efficiencyCPU,
    "M1 Ultra second die")

  print("PASS chip profiles: \(fixtures.count) fixtures (M1…M6, Pro/Max/Ultra, A18 Pro, fanless, unknown), \(MacModelCatalogue.entries.count) Mac models, cross-checked catalogue maps, M4 trust unchanged")
}

private func clusterLayoutChecks() throws {
  let parsed = CPUClusterLayout.parse([(2, "P"), (0, "E"), (1, "E\u{0}"), (3, "S")])
  try require(parsed?.kinds == [.efficiency, .efficiency, .performance, .performance],
    "device-tree layout, super cores count as P")
  try require(CPUClusterLayout.parse([(0, "E"), (2, "P")]) == nil, "gaps in logical ids are rejected")
  try require(CPUClusterLayout.parse([(0, "E"), (0, "P")]) == nil, "duplicate ids are rejected")
  try require(CPUClusterLayout.parse([(0, "")]) == nil, "empty cluster type is rejected")
  try require(CPUClusterLayout.parse([]) == nil, "no cores")
  let fallback = CPUClusterLayout.fallback(performanceCount: 4, efficiencyCount: 6, logicalCount: 10)
  try require(fallback?.kinds.prefix(6).allSatisfy { $0 == .efficiency } == true, "E cores first")
  try require(CPUClusterLayout.fallback(performanceCount: 4, efficiencyCount: 6, logicalCount: 12) == nil,
    "fallback needs the whole CPU")
  let load = fallback?.load(perCoreUsagePercent: [10, 10, 10, 10, 10, 10, 100, 80, 60, 40])
  try require(load?.efficiency == 10 && load?.performance == 70, "cluster load means")
  try require(fallback?.load(perCoreUsagePercent: [1, 2]) == nil, "mismatched core count")
  print("PASS CPU cluster layout: device-tree parsing, E-first fallback and per-cluster load")
}

// MARK: - Passive verification

private struct Temperatures {
  var performance: Double
  var efficiency: Double
  var gpu: Double
}

/// Thermal sample shaped like the reader's output for `profile`: every catalogue key of a
/// group reads the group temperature (plus a little spread), and one raw key is noise.
private func sample(_ profile: MacProfile, _ t: Temperatures, gpuAsleep: Bool = false,
  overrides: [String: Double] = [:]) -> ThermalMetrics {
  let classifier = ThermalClassifier(cpuBrand: profile.cpuBrand, machineModel: profile.machineModel)
  var readings: [ThermalReading] = []
  guard let map = profile.sensorMap else { return ThermalMetrics(readings: [], failures: [:]) }
  for (keys, value) in [(map.performance, t.performance), (map.efficiency, t.efficiency), (map.gpu, t.gpu)] {
    if gpuAsleep, keys == map.gpu { continue }
    for (index, key) in keys.sorted().enumerated() {
      readings.append(ThermalReading(
        key: key, group: classifier.group(for: key),
        celsius: overrides[key] ?? value + Double(index % 3) * 0.2,
        displayGroup: classifier.displayGroup(for: key)))
    }
  }
  readings.append(ThermalReading(key: "TZzz", group: .unclassified, celsius: 99))
  return ThermalMetrics(readings: readings, failures: [:])
}

private let idleLoad = SensorMapVerifier.Load(performance: 3, efficiency: 12, gpu: 2)
private let idleTemps = Temperatures(performance: 45, efficiency: 42, gpu: 40)

private func run(_ verifier: inout SensorMapVerifier, _ profile: MacProfile, count: Int,
  load: SensorMapVerifier.Load, temps: Temperatures, gpuAsleep: Bool = false,
  overrides: [String: Double] = [:]) -> Bool {
  var confirmed = false
  for _ in 0..<count {
    if verifier.observe(sample(profile, temps, gpuAsleep: gpuAsleep, overrides: overrides), load: load) {
      confirmed = true
    }
  }
  return confirmed
}

private func verifierChecks() throws {
  let m4 = MacProfile(machineModel: "Mac16,1", osBuild: "26A434", cpuBrand: "Apple M4",
    performanceCoreCount: 4, efficiencyCoreCount: 6)

  // Idle only: nothing is decided, the UI says what it is waiting for.
  var idleOnly = SensorMapVerifier(profile: m4)
  _ = run(&idleOnly, m4, count: 120, load: idleLoad, temps: idleTemps)
  try require(idleOnly.statuses[.performanceCPU] == .validated, "idle alone confirms nothing")
  try require(idleOnly.statuses[.validatedHotspot] == .validated, "M4 hotspot stays validated")
  try require(idleOnly.detail(for: .performance).contains("Waiting for a while"), "waiting detail")

  // Too little idle: still waiting for a baseline.
  var fresh = SensorMapVerifier(profile: m4)
  _ = run(&fresh, m4, count: 10, load: idleLoad, temps: idleTemps)
  try require(fresh.detail(for: .performance).contains("quiet minute"), "baseline detail")

  // The M0 spike shape: P +10 °C, E +2 °C, GPU +1 °C under P-core load → P confirmed only.
  var spike = SensorMapVerifier(profile: m4)
  _ = run(&spike, m4, count: 60, load: idleLoad, temps: idleTemps)
  let pLoad = SensorMapVerifier.Load(performance: 85, efficiency: 35, gpu: 3)
  let confirmed = run(&spike, m4, count: 30, load: pLoad,
    temps: Temperatures(performance: 55, efficiency: 44, gpu: 41))
  try require(confirmed, "P-core response confirms the P map")
  try require(spike.statuses[.performanceCPU] == .confirmed, "P confirmed")
  try require(spike.statuses[.efficiencyCPU] == .validated, "E untouched by P load")
  try require(spike.statuses[.gpu] == .validated, "GPU untouched by P load")
  if let rise = spike.rise(of: .performance, under: .performance) {
    try require(abs(rise - 10) < 0.5, "P rise ≈ 10 °C, got \(rise)")
  } else {
    throw CheckFailure(description: "P rise missing")
  }

  // Load must settle first: two busy samples are not evidence.
  var unsettled = SensorMapVerifier(profile: m4)
  _ = run(&unsettled, m4, count: 60, load: idleLoad, temps: idleTemps)
  for _ in 0..<40 {
    _ = run(&unsettled, m4, count: 2, load: pLoad, temps: Temperatures(performance: 55, efficiency: 44, gpu: 41))
    _ = run(&unsettled, m4, count: 1, load: idleLoad, temps: idleTemps)
  }
  try require(unsettled.statuses[.performanceCPU] == .validated, "flickering load is not counted")

  // E-cores busy while P rests: E +3 °C, P +0.5 °C → E confirmed.
  var eLoad = SensorMapVerifier(profile: m4)
  _ = run(&eLoad, m4, count: 60, load: idleLoad, temps: idleTemps)
  _ = run(&eLoad, m4, count: 30, load: .init(performance: 5, efficiency: 80, gpu: 2),
    temps: Temperatures(performance: 45.5, efficiency: 45, gpu: 40.2))
  try require(eLoad.statuses[.efficiencyCPU] == .confirmed, "E confirmed")
  try require(eLoad.statuses[.performanceCPU] == .validated, "P not confirmed by E load")

  // GPU busy while the CPU rests: GPU +8 °C, CPU +1 °C → GPU confirmed.
  var gpuLoad = SensorMapVerifier(profile: m4)
  _ = run(&gpuLoad, m4, count: 60, load: idleLoad, temps: idleTemps)
  _ = run(&gpuLoad, m4, count: 30, load: .init(performance: 8, efficiency: 30, gpu: 90),
    temps: Temperatures(performance: 46, efficiency: 43, gpu: 48))
  try require(gpuLoad.statuses[.gpu] == .confirmed, "GPU confirmed")

  // GPU sensors asleep at idle: no GPU baseline, so no GPU verdict, and no crash.
  var asleep = SensorMapVerifier(profile: m4)
  _ = run(&asleep, m4, count: 60, load: idleLoad, temps: idleTemps, gpuAsleep: true)
  _ = run(&asleep, m4, count: 30, load: .init(performance: 8, efficiency: 30, gpu: 90),
    temps: Temperatures(performance: 46, efficiency: 43, gpu: 48))
  try require(asleep.statuses[.gpu] == .validated, "no GPU baseline, no GPU verdict")

  // A catalogue map with swapped P/E labels: the "E" keys warm with P-core load → disputed.
  let m1 = MacProfile(machineModel: "MacBookPro18,3", osBuild: "25A1", cpuBrand: "Apple M1 Pro")
  var swapped = SensorMapVerifier(profile: m1)
  _ = run(&swapped, m1, count: 60, load: idleLoad, temps: idleTemps)
  _ = run(&swapped, m1, count: 40, load: pLoad, temps: Temperatures(performance: 46, efficiency: 54, gpu: 41))
  try require(swapped.statuses[.performanceCPU] == .disputed, "swapped map is disputed")
  try require(swapped.detail(for: .performance).contains("other sensors"), "disputed detail")
  try require(swapped.statuses[.efficiencyCPU] == .catalogue, "E stays catalogue")
  try require(swapped.statuses[.validatedHotspot] == nil, "no hotspot outside M4")

  // A catalogue map that does follow load is confirmed, and confirmation is sticky.
  var good = SensorMapVerifier(profile: m1)
  _ = run(&good, m1, count: 60, load: idleLoad, temps: idleTemps)
  _ = run(&good, m1, count: 30, load: pLoad, temps: Temperatures(performance: 58, efficiency: 45, gpu: 42))
  try require(good.statuses[.performanceCPU] == .confirmed, "M1 Pro P confirmed")
  _ = run(&good, m1, count: 400, load: idleLoad, temps: Temperatures(performance: 60, efficiency: 60, gpu: 60))
  try require(good.statuses[.performanceCPU] == .confirmed, "confirmation is sticky")

  // Flat sensors (no response at all) stay undecided, never disputed.
  var flat = SensorMapVerifier(profile: m1)
  _ = run(&flat, m1, count: 60, load: idleLoad, temps: idleTemps)
  _ = run(&flat, m1, count: 60, load: pLoad, temps: idleTemps)
  try require(flat.statuses[.performanceCPU] == .catalogue, "flat sensors stay catalogue")

  // One family map covers several variants: on a base M2 the catalogue's upper P keys
  // (Tp0n, Tp0r) may sit on E-cores. They do not warm with P load, so they are hidden from
  // the P group while the group itself is confirmed.
  let m2 = MacProfile(machineModel: "Mac14,2", osBuild: "25A1", cpuBrand: "Apple M2")
  var mixed = SensorMapVerifier(profile: m2)
  let stuck = ["Tp0n": 42.0, "Tp0r": 42.2]
  _ = run(&mixed, m2, count: 60, load: idleLoad, temps: idleTemps, overrides: stuck)
  _ = run(&mixed, m2, count: 30, load: pLoad, temps: Temperatures(performance: 57, efficiency: 45, gpu: 41),
    overrides: stuck)
  try require(mixed.statuses[.performanceCPU] == .confirmed, "M2 P confirmed despite two stray keys")
  try require(mixed.excludedKeys == ["Tp0n", "Tp0r"], "stray keys hidden: \(mixed.excludedKeys)")
  try require(mixed.detail(for: .performance).contains("2 sensors did not follow"), "hidden detail")
  try require(spike.excludedKeys.isEmpty, "a coherent group hides nothing")

  // Unknown load (CPU module off) adds no evidence.
  var blind = SensorMapVerifier(profile: m1)
  _ = run(&blind, m1, count: 200, load: .init(), temps: idleTemps)
  try require(blind.evidence.idle.isEmpty, "no load, no evidence")

  // Persistence: round trip, and evidence for another Mac or catalogue is discarded.
  let data = try JSONEncoder().encode(good.evidence)
  let decoded = try JSONDecoder().decode(SensorMapVerifier.Evidence.self, from: data)
  try require(decoded == good.evidence, "evidence round trip")
  try require(SensorMapVerifier(profile: m1, stored: decoded).statuses[.performanceCPU] == .confirmed,
    "stored confirmation restored")
  try require(SensorMapVerifier(profile: m4, stored: decoded).statuses[.performanceCPU] == .validated,
    "evidence of another Mac ignored")
  let defaults = UserDefaults(suiteName: "HeliosChipProfileChecks-\(UUID().uuidString)")!
  SensorMapEvidenceStore.save(good.evidence, to: defaults)
  try require(SensorMapEvidenceStore.load(from: defaults) == good.evidence, "defaults round trip")
  defaults.set(Data(repeating: 0x7b, count: 10), forKey: SensorMapEvidenceStore.defaultsKey)
  try require(SensorMapEvidenceStore.load(from: defaults) == nil, "corrupt evidence ignored")

  // Old evidence decays so the baseline follows the room and season.
  var accumulator = SensorMapVerifier.Accumulator()
  for _ in 0..<10 { accumulator.add(40, decayAfter: 8) }
  try require(accumulator.count <= 8 && accumulator.mean == 40, "decay keeps the mean")
  print("PASS passive sensor-map verification: idle/P/E/GPU response, settling, disputes, stickiness, persistence and decay")
}

/// Replays the real M0 series saved from Mac16,1 (macOS 26A434, 1 s cadence). Its "load"
/// column marks 25 s of a 3-thread CPU loop, but the saved temperatures show no response
/// (P keys stay at 46 °C ± 0.5). The "+10 °C" quoted in PLAN M0 came from a run that was not
/// saved. So this is real negative evidence: a flagged load without warming must neither
/// confirm nor dispute a map. Sample minimums are relaxed because the series is short.
private func realSeriesChecks() throws {
  let url = URL(fileURLWithPath: "Tests/Fixtures/m4-cpu-load-series.csv")
  let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
  guard let header = lines.first?.split(separator: ",").map(String.init), header.count > 2 else {
    throw CheckFailure(description: "real series header")
  }
  let keys = header.dropFirst(2).map { $0.replacingOccurrences(of: "S:", with: "") }
  let m4 = MacProfile(machineModel: "Mac16,1", osBuild: "26A434", cpuBrand: "Apple M4",
    performanceCoreCount: 4, efficiencyCoreCount: 6)
  let classifier = ThermalClassifier(cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "26A434")
  var thresholds = SensorMapVerifier.Thresholds.standard
  thresholds.minimumIdleSamples = 10
  thresholds.minimumActiveSamples = 10
  var verifier = SensorMapVerifier(profile: m4, thresholds: thresholds)
  var rows = 0
  for line in lines.dropFirst() {
    let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == header.count else { continue }
    var readings: [ThermalReading] = []
    for (key, field) in zip(keys, fields.dropFirst(2)) {
      guard let celsius = Double(field), celsius > 10 else { continue }
      readings.append(ThermalReading(key: key, group: classifier.group(for: key), celsius: celsius,
        displayGroup: classifier.displayGroup(for: key)))
    }
    let busy = fields[1] == "1"
    verifier.observe(ThermalMetrics(readings: readings, failures: [:]),
      load: busy ? .init(performance: 75, efficiency: 20, gpu: 2) : idleLoad)
    rows += 1
  }
  try require(rows == 60, "real series rows \(rows)")
  let rise = verifier.rise(of: .performance, under: .performance)
  try require(rise.map { abs($0) < 1 } == true, "real series shows no P response: \(String(describing: rise))")
  try require(verifier.statuses[.performanceCPU] == .validated, "no response, no confirmation")
  try require(verifier.statuses[.efficiencyCPU] == .validated, "E undecided")
  try require(verifier.statuses[.gpu] == .validated, "GPU undecided")
  print(String(format: "PASS real Mac16,1 series: flagged load without warming (P %+.1f °C) neither confirms nor disputes", rise ?? 0))
}

// MARK: - Anonymous SMC dump

private final class DumpTransport: SMCReadTransport {
  let values: [String: (type: String, bytes: [UInt8], attr: UInt8)]
  let keys: [String]

  init(_ values: [String: (type: String, bytes: [UInt8], attr: UInt8)]) {
    var complete = values
    let keys = Array(Set(values.keys).union(["#KEY"])).sorted()
    let count = UInt32(keys.count)
    complete["#KEY"] = ("ui32", [0, 0, UInt8(count >> 8), UInt8(truncatingIfNeeded: count)], 0x80)
    self.values = complete
    self.keys = keys
  }

  func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
    var reply = [UInt8](repeating: 0, count: SMCCodec.frameSize)
    switch request.command {
    case .keyAtIndex:
      put(try SMCCodec.fourCC(keys[Int(request.index)]), &reply, 0)
    case .keyInfo:
      guard let value = values[request.key] else { throw TelemetryError.smc(request.key, 0x84) }
      put(UInt32(value.bytes.count), &reply, 28)
      put(try SMCCodec.fourCC(value.type), &reply, 32)
      reply[36] = value.attr
    case .bytes:
      guard let value = values[request.key] else { throw TelemetryError.smc(request.key, 0x84) }
      reply.replaceSubrange(48..<(48 + value.bytes.count), with: value.bytes)
    }
    return reply
  }

  private func put(_ value: UInt32, _ bytes: inout [UInt8], _ offset: Int) {
    for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8)) }
  }
}

private func dumpChecks() throws {
  let temperature = Float(52.5).bitPattern
  let transport = DumpTransport([
    // Apple Silicon `flt` values are little-endian.
    "Tp01": ("flt ", [UInt8(truncatingIfNeeded: temperature), UInt8(truncatingIfNeeded: temperature >> 8),
      UInt8(truncatingIfNeeded: temperature >> 16), UInt8(temperature >> 24)], 0x80),
    "Ftst": ("ui8 ", [0], 0xd0),
    "F0Mx": ("ui16", [0x17, 0x70], 0x85),
    "RSER": ("ch8*", Array("C02SECRET".utf8), 0x80),
    "BLOB": ("{abc", [1, 2, 3], 0x80),
  ])
  let profile = MacProfile(machineModel: "Mac16,1", osBuild: "26A434", cpuBrand: "Apple M4",
    performanceCoreCount: 4, efficiencyCoreCount: 6)
  let text = try SMCDump.make(transport: transport, profile: profile,
    date: Date(timeIntervalSince1970: 1_791_936_000))
  let lines = text.split(separator: "\n").map(String.init)
  try require(lines.first == "# Helios SMC dump v1", "dump header")
  try require(lines[1] == "# model=Mac16,1 chip=Apple M4 build=26A434 cores=4P+6E keys=6 date=2026-10-14",
    "dump identity line: \(lines[1])")
  try require(lines.contains("Tp01\tflt \t4\t80\t52.50"), "temperature decoded")
  try require(lines.contains("Ftst\tui8 \t1\td0\t0"), "attribute byte and integer")
  try require(lines.contains("F0Mx\tui16\t2\t85\t6000"), "big-endian ui16")
  try require(lines.contains("RSER\tch8*\t9\t80\t"), "text key listed without value")
  try require(lines.contains("BLOB\t{abc\t3\t80\t"), "structure listed without value")
  try require(!text.contains("SECRET") && !text.contains("C02"), "text values never leave the Mac")
  try require(SMCDump.suggestedFileName(profile) == "Helios-SMC-Mac16,1-M4-26A434.tsv",
    "file name \(SMCDump.suggestedFileName(profile))")
  try require(SMCDump.isShareableNumeric(type: "sp78") && SMCDump.isShareableNumeric(type: "fp88"),
    "fixed-point types are numeric")
  try require(!SMCDump.isShareableNumeric(type: "hex_") && !SMCDump.isShareableNumeric(type: "spzz"),
    "hex and malformed types are not")
  try require(SensorMapCalibration.shouldAbort(thermalState: .serious, hottestCelsius: 50), "calibration stops at serious pressure")
  try require(SensorMapCalibration.shouldAbort(thermalState: .nominal, hottestCelsius: 90), "calibration stops at 90 °C")
  try require(!SensorMapCalibration.shouldAbort(thermalState: .fair, hottestCelsius: 80), "calibration continues when fair")
  try require(!SensorMapCalibration.shouldAbort(thermalState: nil, hottestCelsius: nil), "unknown state does not abort")
  print("PASS anonymous SMC dump: identity line, attributes, numeric values; text and blobs left out")
}

// MARK: - Alerts follow trusted maps only

private func alertChecks() throws {
  let catalogueReading = ThermalReading(key: "Tp01", group: .unclassified, celsius: 99,
    displayGroup: .performanceCPU)
  var metrics = ThermalMetrics(readings: [catalogueReading], failures: [:])
  try require((try? metrics.maximumSoCCelsius.get()) == 99, "catalogue reading still shown")
  try require((try? metrics.alertMaximumSoCCelsius.get()) == nil, "no alert before verification")
  metrics.mapStatus = [.performanceCPU: .catalogue]
  try require((try? metrics.alertMaximumSoCCelsius.get()) == nil, "catalogue map does not alert")
  try require(metrics.maximumSoCMapStatus == .catalogue, "headline is labelled catalogue")
  metrics.mapStatus = [.performanceCPU: .disputed]
  try require((try? metrics.alertMaximumSoCCelsius.get()) == nil, "disputed map does not alert")
  metrics.mapStatus = [.performanceCPU: .confirmed]
  try require((try? metrics.alertMaximumSoCCelsius.get()) == 99, "confirmed map alerts")

  let trusted = ThermalMetrics(
    readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 97)], failures: [:])
  try require((try? trusted.alertMaximumSoCCelsius.get()) == 97, "validated M4 map alerts as before")
  try require(trusted.maximumSoCMapStatus == .validated, "validated headline status")

  var snapshot = TelemetrySnapshot()
  snapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [catalogueReading], failures: [:])))
  try require(!HealthEvaluator.evaluate(snapshot).contains { $0.id.hasPrefix("soc-") },
    "catalogue temperature raises no SoC alert")
  snapshot.thermals = MetricSample(.success(trusted))
  try require(HealthEvaluator.evaluate(snapshot).contains { $0.id == "soc-critical" },
    "trusted temperature still raises the critical alert")
  print("PASS health alerts use only validated or confirmed sensor maps; catalogue readings stay informational")
}

@main
private struct ChipProfileChecks {
  static func main() {
    do {
      try profileChecks()
      try clusterLayoutChecks()
      try verifierChecks()
      try realSeriesChecks()
      try dumpChecks()
      try alertChecks()
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
