import Foundation
import IOKit

extension SensorCatalogue.Map {
  func group(for key: String) -> ThermalGroup {
    if performance.contains(key) { return .performanceCPU }
    if efficiency.contains(key) { return .efficiencyCPU }
    if gpu.contains(key) { return .gpu }
    return .unclassified
  }

  func keys(in group: ThermalGroup) -> Set<String> {
    switch group {
    case .performanceCPU: performance
    case .efficiencyCPU: efficiency
    case .gpu: gpu
    case .validatedHotspot, .unclassified: []
    }
  }
}

/// How far Helios trusts the key → group mapping for one sensor group on this Mac.
/// Shown next to temperatures; an unconfirmed temperature never looks like a confirmed one.
enum SensorMapStatus: String, Sendable, Codable, CaseIterable {
  /// This Mac's own telemetry showed the group's sensors following its load.
  case confirmed
  /// The physically validated map for this chip family (today M4), not yet seen to
  /// follow load on this particular Mac.
  case validated
  /// Copied from a public sensor catalogue and not yet confirmed here.
  case catalogue
  /// Catalogue map whose sensors followed a different group's load on this Mac.
  case disputed
  /// No map for this chip.
  case unknown

  var title: String {
    switch self {
    case .confirmed: "Confirmed on this Mac"
    case .validated: "Validated for this chip"
    case .catalogue: "From catalogue, may be inaccurate"
    case .disputed: "From catalogue, does not match this Mac"
    case .unknown: "Unknown chip"
    }
  }

  /// Whether a temperature from this group may raise health alerts. Catalogue maps stay
  /// informational until this Mac confirms them (PLAN_0_3_0 §8.1).
  var isTrustedForAlerts: Bool { self == .confirmed || self == .validated }
}

/// Apple Silicon Macs by model identifier (Stats model list, Apple specifications).
/// Informational: the chip always comes from the CPU brand and fans from the SMC. `fans`
/// is the expected count where it is certain (fanless Airs, 1-fan 13"/14" base, 2-fan
/// 14"/16" Pro/Max, Mac mini); nil where it varies or is not documented.
enum MacModelCatalogue {
  enum Kind: String, Sendable {
    case laptop
    case desktop
  }

  struct Entry: Sendable, Equatable {
    let name: String
    let chip: String
    let kind: Kind
    let fans: Int?
  }

  static let entries: [String: Entry] = [
    "MacBookAir10,1": Entry(name: "MacBook Air 13″ (M1, 2020)", chip: "M1", kind: .laptop, fans: 0),
    "MacBookPro17,1": Entry(name: "MacBook Pro 13″ (M1, 2020)", chip: "M1", kind: .laptop, fans: 1),
    "Macmini9,1": Entry(name: "Mac mini (M1, 2020)", chip: "M1", kind: .desktop, fans: 1),
    "iMac21,1": Entry(name: "iMac 24″ (M1, 2021)", chip: "M1", kind: .desktop, fans: nil),
    "iMac21,2": Entry(name: "iMac 24″ (M1, 2021)", chip: "M1", kind: .desktop, fans: nil),
    "MacBookPro18,1": Entry(name: "MacBook Pro 16″ (M1 Pro, 2021)", chip: "M1 Pro", kind: .laptop, fans: 2),
    "MacBookPro18,2": Entry(name: "MacBook Pro 16″ (M1 Max, 2021)", chip: "M1 Max", kind: .laptop, fans: 2),
    "MacBookPro18,3": Entry(name: "MacBook Pro 14″ (M1 Pro, 2021)", chip: "M1 Pro", kind: .laptop, fans: 2),
    "MacBookPro18,4": Entry(name: "MacBook Pro 14″ (M1 Max, 2021)", chip: "M1 Max", kind: .laptop, fans: 2),
    "Mac13,1": Entry(name: "Mac Studio (M1 Max, 2022)", chip: "M1 Max", kind: .desktop, fans: nil),
    "Mac13,2": Entry(name: "Mac Studio (M1 Ultra, 2022)", chip: "M1 Ultra", kind: .desktop, fans: nil),
    "Mac14,2": Entry(name: "MacBook Air 13″ (M2, 2022)", chip: "M2", kind: .laptop, fans: 0),
    "Mac14,7": Entry(name: "MacBook Pro 13″ (M2, 2022)", chip: "M2", kind: .laptop, fans: 1),
    "Mac14,15": Entry(name: "MacBook Air 15″ (M2, 2023)", chip: "M2", kind: .laptop, fans: 0),
    "Mac14,3": Entry(name: "Mac mini (M2, 2023)", chip: "M2", kind: .desktop, fans: 1),
    "Mac14,12": Entry(name: "Mac mini (M2 Pro, 2023)", chip: "M2 Pro", kind: .desktop, fans: 1),
    "Mac14,5": Entry(name: "MacBook Pro 14″ (M2 Max, 2023)", chip: "M2 Max", kind: .laptop, fans: 2),
    "Mac14,6": Entry(name: "MacBook Pro 16″ (M2 Max, 2023)", chip: "M2 Max", kind: .laptop, fans: 2),
    "Mac14,9": Entry(name: "MacBook Pro 14″ (M2 Pro, 2023)", chip: "M2 Pro", kind: .laptop, fans: 2),
    "Mac14,10": Entry(name: "MacBook Pro 16″ (M2 Pro, 2023)", chip: "M2 Pro", kind: .laptop, fans: 2),
    "Mac14,13": Entry(name: "Mac Studio (M2 Max, 2023)", chip: "M2 Max", kind: .desktop, fans: nil),
    "Mac14,14": Entry(name: "Mac Studio (M2 Ultra, 2023)", chip: "M2 Ultra", kind: .desktop, fans: nil),
    "Mac14,8": Entry(name: "Mac Pro (M2 Ultra, 2023)", chip: "M2 Ultra", kind: .desktop, fans: nil),
    "Mac15,3": Entry(name: "MacBook Pro 14″ (M3, 2023)", chip: "M3", kind: .laptop, fans: 1),
    "Mac15,4": Entry(name: "iMac 24″ (M3, 2023)", chip: "M3", kind: .desktop, fans: nil),
    "Mac15,5": Entry(name: "iMac 24″ (M3, 2023)", chip: "M3", kind: .desktop, fans: nil),
    "Mac15,6": Entry(name: "MacBook Pro 14″ (M3 Pro, 2023)", chip: "M3 Pro", kind: .laptop, fans: 2),
    "Mac15,7": Entry(name: "MacBook Pro 16″ (M3 Pro, 2023)", chip: "M3 Pro", kind: .laptop, fans: 2),
    "Mac15,8": Entry(name: "MacBook Pro 14″ (M3 Max, 2023)", chip: "M3 Max", kind: .laptop, fans: 2),
    "Mac15,9": Entry(name: "MacBook Pro 16″ (M3 Max, 2023)", chip: "M3 Max", kind: .laptop, fans: 2),
    "Mac15,10": Entry(name: "MacBook Pro 14″ (M3 Max, 2023)", chip: "M3 Max", kind: .laptop, fans: 2),
    "Mac15,11": Entry(name: "MacBook Pro 16″ (M3 Max, 2023)", chip: "M3 Max", kind: .laptop, fans: 2),
    "Mac15,12": Entry(name: "MacBook Air 13″ (M3, 2024)", chip: "M3", kind: .laptop, fans: 0),
    "Mac15,13": Entry(name: "MacBook Air 15″ (M3, 2024)", chip: "M3", kind: .laptop, fans: 0),
    "Mac15,14": Entry(name: "Mac Studio (M3 Ultra, 2025)", chip: "M3 Ultra", kind: .desktop, fans: nil),
    "Mac16,1": Entry(name: "MacBook Pro 14″ (M4, 2024)", chip: "M4", kind: .laptop, fans: 1),
    "Mac16,2": Entry(name: "iMac 24″ (M4, 2024)", chip: "M4", kind: .desktop, fans: nil),
    "Mac16,3": Entry(name: "iMac 24″ (M4, 2024)", chip: "M4", kind: .desktop, fans: nil),
    "Mac16,5": Entry(name: "MacBook Pro 16″ (M4 Max, 2024)", chip: "M4 Max", kind: .laptop, fans: 2),
    "Mac16,6": Entry(name: "MacBook Pro 14″ (M4 Max, 2024)", chip: "M4 Max", kind: .laptop, fans: 2),
    "Mac16,7": Entry(name: "MacBook Pro 16″ (M4 Pro, 2024)", chip: "M4 Pro", kind: .laptop, fans: 2),
    "Mac16,8": Entry(name: "MacBook Pro 14″ (M4 Pro, 2024)", chip: "M4 Pro", kind: .laptop, fans: 2),
    "Mac16,9": Entry(name: "Mac Studio (M4 Max, 2025)", chip: "M4 Max", kind: .desktop, fans: nil),
    "Mac16,10": Entry(name: "Mac mini (M4, 2024)", chip: "M4", kind: .desktop, fans: 1),
    "Mac16,11": Entry(name: "Mac mini (M4 Pro, 2024)", chip: "M4 Pro", kind: .desktop, fans: 1),
    "Mac16,12": Entry(name: "MacBook Air 13″ (M4, 2025)", chip: "M4", kind: .laptop, fans: 0),
    "Mac16,13": Entry(name: "MacBook Air 15″ (M4, 2025)", chip: "M4", kind: .laptop, fans: 0),
    "Mac17,2": Entry(name: "MacBook Pro 14″ (M5, 2025)", chip: "M5", kind: .laptop, fans: 1),
    "Mac17,3": Entry(name: "MacBook Air 13″ (M5, 2026)", chip: "M5", kind: .laptop, fans: 0),
    "Mac17,4": Entry(name: "MacBook Air 15″ (M5, 2026)", chip: "M5", kind: .laptop, fans: 0),
    "Mac17,5": Entry(name: "MacBook Neo (A18 Pro, 2026)", chip: "A18 Pro", kind: .laptop, fans: nil),
    "Mac17,6": Entry(name: "MacBook Pro 16″ (M5 Max, 2026)", chip: "M5 Max", kind: .laptop, fans: 2),
    "Mac17,7": Entry(name: "MacBook Pro 14″ (M5 Max, 2026)", chip: "M5 Max", kind: .laptop, fans: 2),
    "Mac17,8": Entry(name: "MacBook Pro 16″ (M5 Pro, 2026)", chip: "M5 Pro", kind: .laptop, fans: 2),
    "Mac17,9": Entry(name: "MacBook Pro 14″ (M5 Pro, 2026)", chip: "M5 Pro", kind: .laptop, fans: 2),
    "Mac17,14": Entry(name: "Mac Studio (M5 Max, 2026)", chip: "M5 Max", kind: .desktop, fans: nil),
    "Mac17,15": Entry(name: "Mac Studio (M5 Ultra, 2026)", chip: "M5 Ultra", kind: .desktop, fans: nil),
    "Mac17,16": Entry(name: "Mac mini (M5 Pro, 2026)", chip: "M5 Pro", kind: .desktop, fans: 1),
    "Mac18,5": Entry(name: "Mac mini (M6, 2026)", chip: "M6", kind: .desktop, fans: 1),
  ]
}

/// Logical CPU → cluster kind, from the device tree (`cpus/cpuN` `cluster-type`).
/// Needed to tell P-core load from E-core load for passive sensor-map verification.
struct CPUClusterLayout: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case performance
    case efficiency
  }

  /// Indexed by logical CPU id; the same order as `host_processor_info`.
  let kinds: [Kind]

  /// Apple Silicon lists the efficiency cores first. Used only when the device tree
  /// cannot be read; nil when the counts do not describe the whole CPU.
  static func fallback(performanceCount: Int?, efficiencyCount: Int?, logicalCount: Int) -> Self? {
    guard let performanceCount, let efficiencyCount, performanceCount + efficiencyCount == logicalCount,
      logicalCount > 0
    else { return nil }
    return Self(
      kinds: Array(repeating: .efficiency, count: efficiencyCount)
        + Array(repeating: .performance, count: performanceCount))
  }

  /// "E" is efficiency; every other cluster type ("P", M5/M6 "super" cores) counts as
  /// performance, matching how the sensor catalogue folds super cores into P.
  static func parse(_ entries: [(logicalID: Int, clusterType: String)]) -> Self? {
    guard !entries.isEmpty, entries.count <= 512 else { return nil }
    let ids = entries.map(\.logicalID).sorted()
    guard ids == Array(0..<entries.count) else { return nil }
    var kinds = [Kind](repeating: .performance, count: entries.count)
    for entry in entries {
      let type = entry.clusterType.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
      guard !type.isEmpty else { return nil }
      kinds[entry.logicalID] = type == "E" ? .efficiency : .performance
    }
    return Self(kinds: kinds)
  }

  static func native() -> Self? {
    let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
    guard cpus != MACH_PORT_NULL else { return nil }
    defer { IOObjectRelease(cpus) }
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    var entries: [(logicalID: Int, clusterType: String)] = []
    while case let entry = IOIteratorNext(iterator), entry != MACH_PORT_NULL {
      defer { IOObjectRelease(entry) }
      guard let id = integer(property("logical-cpu-id", of: entry)),
        let type = text(property("cluster-type", of: entry))
      else { continue }
      entries.append((id, type))
      if entries.count > 512 { return nil }
    }
    return parse(entries)
  }

  /// Mean busy percent of each cluster, or nil when the per-core list does not match.
  func load(perCoreUsagePercent usage: [Double]) -> (performance: Double?, efficiency: Double?)? {
    guard usage.count == kinds.count, !usage.isEmpty else { return nil }
    var performance: [Double] = []
    var efficiency: [Double] = []
    for (kind, value) in zip(kinds, usage) where value.isFinite {
      switch kind {
      case .performance: performance.append(value)
      case .efficiency: efficiency.append(value)
      }
    }
    func mean(_ values: [Double]) -> Double? {
      values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    return (mean(performance), mean(efficiency))
  }

  private static func property(_ name: String, of entry: io_registry_entry_t) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
  }

  private static func integer(_ value: CFTypeRef?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let data = value as? Data, (1...8).contains(data.count) {
      // Device-tree cells are little-endian on Apple Silicon.
      return data.reversed().reduce(0) { ($0 << 8) | Int($1) }
    }
    return nil
  }

  private static func text(_ value: CFTypeRef?) -> String? {
    if let string = value as? String { return string }
    if let data = value as? Data, data.count <= 16 {
      return String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return nil
  }
}

/// What Helios knows about this Mac: chip, cores and which sensor map applies.
/// Read-only; it never authorizes fan control (the helper keeps its own exact gates).
struct MacProfile: Sendable, Equatable {
  let machineModel: String
  let osBuild: String
  let cpuBrand: String
  let chip: ChipIdentity?
  let performanceCoreCount: Int?
  let efficiencyCoreCount: Int?

  init(machineModel: String, osBuild: String, cpuBrand: String,
    performanceCoreCount: Int? = nil, efficiencyCoreCount: Int? = nil) {
    self.machineModel = machineModel
    self.osBuild = osBuild
    self.cpuBrand = cpuBrand
    self.chip = ChipIdentity(brand: cpuBrand)
    self.performanceCoreCount = performanceCoreCount
    self.efficiencyCoreCount = efficiencyCoreCount
  }

  var sensorMap: SensorCatalogue.Map? { SensorCatalogue.map(for: chip) }

  /// The catalogue entry for this model identifier, when Helios knows it.
  var model: MacModelCatalogue.Entry? { MacModelCatalogue.entries[machineModel] }

  /// Status before this Mac's own telemetry has confirmed anything.
  func baselineStatus(for group: ThermalGroup) -> SensorMapStatus {
    guard let map = sensorMap else { return .unknown }
    switch group {
    case .validatedHotspot: return .validated
    case .unclassified: return .unknown
    case .performanceCPU, .efficiencyCPU, .gpu:
      guard !map.keys(in: group).isEmpty else { return .unknown }
      return map.source == .validated ? .validated : .catalogue
    }
  }

  /// "MacBook Pro 14″ (M4, 2024) · 4 P + 6 E cores", for the sensor-map section and reports.
  var summary: String {
    var text = model?.name
      ?? chip.map { "Apple \($0.name)" } ?? (cpuBrand.isEmpty ? "Unknown chip" : cpuBrand)
    if let performanceCoreCount, let efficiencyCoreCount {
      text += efficiencyCoreCount > 0
        ? " · \(performanceCoreCount) P + \(efficiencyCoreCount) E cores"
        : " · \(performanceCoreCount) cores"
    }
    return text
  }

  /// Stable per-Mac key for stored verification evidence. A new catalogue version or a
  /// different chip/model starts over; an OS update does not.
  var evidenceKey: String { "\(machineModel)|\(cpuBrand)|catalogue-\(SensorCatalogue.version)" }

  static func native() -> Self {
    let topology = CPUTopologyReader.read()
    return Self(
      machineModel: (try? ThermalClassifier.sysctlString("hw.model")) ?? "",
      osBuild: (try? ThermalClassifier.sysctlString("kern.osversion")) ?? "",
      cpuBrand: (try? ThermalClassifier.sysctlString("machdep.cpu.brand_string")) ?? "",
      performanceCoreCount: try? topology.performanceCoreCount.get(),
      efficiencyCoreCount: try? topology.efficiencyCoreCount.get())
  }
}
