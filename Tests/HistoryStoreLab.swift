import Foundation

/// Offline lab for the local history stores. Uses the real store code against a
/// generated file in a scratch directory (never the user's Application Support).
/// Usage: HistoryStoreLab <scratch-directory> [buckets] [apps-per-bucket]
/// First run generates the file and exits; run again with HELIOS_LAB_LOAD_ONLY=1
/// to measure loading in a fresh process (clean footprint/peak).
@main
enum HistoryStoreLab {
  static func main() async {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { print("usage: HistoryStoreLab <dir> [buckets] [apps]"); exit(2) }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let bucketCount = arguments.count > 2 ? Int(arguments[2]) ?? 10_080 : 10_080
    let appsPerBucket = arguments.count > 3 ? Int(arguments[3]) ?? 24 : 24
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("app-energy-lab.ndjson")
    let now = Date()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let loadOnly = ProcessInfo.processInfo.environment["HELIOS_LAB_LOAD_ONLY"] == "1"
    var fileMB = 0.0
    if !loadOnly {

    // Realistic keys: distinct apps, long bundle paths, nested helpers.
    let apps = (0..<60).map { index -> (String, String) in
      let name = ["Safari", "Xcode", "Visual Studio Code", "Claude", "Codex", "Mail", "Music",
        "Obsidian", "Discord", "Finder"][index % 10] + (index >= 10 ? " \(index)" : "")
      return ("app:/Applications/\(name).app/Contents/Frameworks/\(name) Helper (Renderer).app", name)
    }
    var data = Data()
    for index in 0..<bucketCount {
      let entries = (0..<appsPerBucket).map { offset -> AppEnergyEntry in
        let app = apps[(index + offset * 7) % apps.count]
        return AppEnergyEntry(appKey: app.0, displayName: app.1, energyWattHours: 0.0123456789,
          cpuCoreSeconds: 3.14159, wakeups: 123.456, peakMemoryBytes: 734_003_200)
      }
      let bucket = AppEnergyBucket(
        capturedAt: now.addingTimeInterval(-Double(bucketCount - index) * 60), durationSeconds: 60,
        onBattery: (index / 600) % 2 == 0, batteryPercent: 80, entries: entries)
      data.append(try! encoder.encode(bucket))
      data.append(0x0A)
    }
    try! data.write(to: url)
    print(String(format: "generated %.1f MB", Double(data.count) / 1_048_576))
    exit(0)
    }
    fileMB = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_048_576

    let before = footprint()
    let started = Date()
    let store = AppEnergyHistoryStore(url: url)
    let summary = await store.current(now: now)
    let loadSeconds = Date().timeIntervalSince(started)
    let after = footprint()
    // Cost of one full rewrite as performed by compaction (encode + atomic write).
    let rewriteStart = Date()
    var rewrite = Data()
    for bucket in summary.buckets { rewrite.append(try! encoder.encode(bucket)); rewrite.append(0x0A) }
    try! rewrite.write(to: directory.appendingPathComponent("rewrite.ndjson"), options: .atomic)
    let rewriteSeconds = Date().timeIntervalSince(rewriteStart)
    let rewriteMB = Double(rewrite.count) / 1_048_576
    rewrite = Data()
    let summaryStart = Date()
    _ = AppEnergyHistoryEngine.summary(summary.buckets)
    let summarySeconds = Date().timeIntervalSince(summaryStart)

    print(String(format: "file %.1f MB, %d buckets; load %.2fs; footprint %.1f → %.1f MB (peak %.1f MB)",
      fileMB, summary.buckets.count, loadSeconds, before.current, after.current, after.peak))
    print(String(format: "one compaction rewrite: %.1f MB in %.2fs; summary recompute %.3fs", rewriteMB,
      rewriteSeconds, summarySeconds))
    try? FileManager.default.removeItem(at: directory)
  }

  static func footprint() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
  }
}
