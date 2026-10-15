import Foundation

/// What macOS itself wrote into its diagnostic report folders: kernel panics, memory
/// kills (Jetsam), app crashes and the resource reports it files when a process used too
/// much CPU, woke the Mac too often or wrote too much. Read-only, local only: file names
/// carry the computer's name, so only the process name, kind and date are kept, and none
/// of it ever enters a diagnostics report (PLAN_0_3_0 §0).
struct DiagnosticReportSummary: Sendable, Equatable {
  enum Kind: String, Sendable, Equatable {
    case kernelPanic
    case memoryKill
    case appCrash
    case cpuResource
    case wakeupsResource
    case diskWritesResource
  }

  /// Why the kernel panicked, from keywords in the report (panics only).
  enum PanicCause: String, Sendable, Equatable {
    case watchdog
    case sleepWake
    case gpu
    case thermal
    case other

    var text: String {
      switch self {
      case .watchdog: "a system process stopped responding (watchdog)"
      case .sleepWake: "a sleep or wake failure"
      case .gpu: "a graphics (GPU) failure"
      case .thermal: "a thermal emergency"
      case .other: "a kernel error"
      }
    }
  }

  let kind: Kind
  /// Process the report is about; nil for panics and memory kills.
  let process: String?
  let date: Date
  var panicCause: PanicCause? = nil
}

enum DiagnosticReportsReader {
  static let systemFolder = "/Library/Logs/DiagnosticReports"
  static let maximumFiles = 400
  static let panicReadBytes = 64 * 1024

  /// Reports newer than `since`, newest first. Never throws: an unreadable folder is empty.
  static func read(folders: [String] = [systemFolder, NSHomeDirectory() + "/Library/Logs/DiagnosticReports"],
                   since: Date, fileManager: FileManager = .default) -> [DiagnosticReportSummary] {
    var result: [(URL, DiagnosticReportSummary)] = []
    for folder in folders {
      let url = URL(fileURLWithPath: folder, isDirectory: true)
      guard let entries = try? fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
      else { continue }
      // The listing is unordered and the folder can hold years of reports: filter by date
      // first, so the cap never hides a recent one behind old files.
      for entry in entries {
        guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
          values.isRegularFile == true, let date = values.contentModificationDate, date >= since,
          let summary = classify(fileName: entry.lastPathComponent, date: date)
        else { continue }
        result.append((entry, summary))
      }
    }
    return result.sorted { $0.1.date > $1.1.date }.prefix(maximumFiles).map { entry, summary in
      var summary = summary
      if summary.kind == .kernelPanic { summary.panicCause = panicCause(of: entry) }
      return summary
    }
  }

  /// Pure, from the file name alone. nil for files Helios does not interpret.
  static func classify(fileName name: String, date: Date) -> DiagnosticReportSummary? {
    let lower = name.lowercased()
    if lower.hasSuffix(".panic") || lower.hasPrefix("panic") || lower.hasPrefix("kernel-") {
      return DiagnosticReportSummary(kind: .kernelPanic, process: nil, date: date)
    }
    if lower.hasPrefix("jetsamevent") {
      return DiagnosticReportSummary(kind: .memoryKill, process: nil, date: date)
    }
    let resource: [(String, DiagnosticReportSummary.Kind)] = [
      (".cpu_resource.", .cpuResource), (".wakeups_resource.", .wakeupsResource),
      (".diskwrites_resource.", .diskWritesResource),
    ]
    for (marker, kind) in resource where lower.contains(marker) {
      return DiagnosticReportSummary(kind: kind, process: processName(name), date: date)
    }
    if lower.hasSuffix(".ips"), !lower.hasPrefix("excuserfault"), !lower.hasPrefix("preferencesprobe") {
      return DiagnosticReportSummary(kind: .appCrash, process: processName(name), date: date)
    }
    return nil
  }

  /// "Safari_2026-10-09-114031_Host.cpu_resource.diag" or "Safari-2026-10-09-114031.ips" → "Safari".
  static func processName(_ fileName: String) -> String? {
    guard let range = fileName.range(of: #"[_-]\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else {
      return nil
    }
    let name = String(fileName[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= 80 else { return nil }
    return name
  }

  static func panicCause(text: String) -> DiagnosticReportSummary.PanicCause {
    let lower = text.lowercased()
    if lower.contains("watchdog") { return .watchdog }
    if lower.contains("sleep wake") || lower.contains("sleepwake") || lower.contains("sleep/wake") { return .sleepWake }
    if lower.contains("thermal") { return .thermal }
    if lower.contains("gpu") || lower.contains("agx") { return .gpu }
    return .other
  }

  private static func panicCause(of url: URL) -> DiagnosticReportSummary.PanicCause {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: panicReadBytes)) ?? Data()
    return panicCause(text: String(decoding: data, as: UTF8.self))
  }
}
