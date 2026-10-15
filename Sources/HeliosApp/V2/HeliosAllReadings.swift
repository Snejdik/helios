import SwiftUI

/// Every value the telemetry layer publishes, for people who want the raw numbers. Built by
/// reflection over one frozen snapshot, so a new field shows up here without UI work, and
/// nothing is computed until the disclosure is opened. Shown only on this Mac.
enum HeliosReadingTree {
  struct Row: Identifiable, Equatable {
    let path: String
    let value: String
    var id: String { path }
  }

  struct Group: Identifiable, Equatable {
    let name: String
    let rows: [Row]
    var id: String { name }
  }

  static let maximumDepth = 7
  static let maximumItems = 40
  static let maximumRows = 600

  /// The live snapshot's samplers, then the summaries kept beside it (history, I/O, energy).
  static func groups(_ snapshot: TelemetrySnapshot, extra: [(String, Any)] = []) -> [Group] {
    let live: [(String, Any)] = Mirror(reflecting: snapshot).children.compactMap { child in
      child.label.map { ($0, child.value) }
    }
    return (live + extra).map { name, value in
      var rows: [Row] = []
      flatten(value, path: "", depth: 0, into: &rows)
      return Group(name: name, rows: rows)
    }
  }

  static func flatten(_ value: Any, path: String, depth: Int, into rows: inout [Row]) {
    guard rows.count < maximumRows else { return }
    if let leaf = leafText(value) {
      rows.append(Row(path: path.isEmpty ? "value" : path, value: leaf))
      return
    }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      if let some = mirror.children.first {
        flatten(some.value, path: path, depth: depth, into: &rows)
      } else {
        rows.append(Row(path: path.isEmpty ? "value" : path, value: "—"))
      }
      return
    }
    guard depth < maximumDepth, !mirror.children.isEmpty else {
      rows.append(Row(path: path.isEmpty ? "value" : path, value: String(describing: value)))
      return
    }
    let isList = mirror.displayStyle == .collection || mirror.displayStyle == .set
      || mirror.displayStyle == .dictionary
    for (index, child) in mirror.children.enumerated() {
      if isList, index >= maximumItems {
        rows.append(Row(path: "\(path)[…]", value: "\(mirror.children.count - maximumItems) more"))
        break
      }
      // Enum payloads (Result.success / .failure) read as the case name in the path.
      let label = isList ? "[\(index)]" : (child.label ?? "\(index)")
      // A sample's `result.success` wrapper says nothing; a failure keeps its name.
      if !isList, label == "result" || label == "success" {
        flatten(child.value, path: path, depth: depth + 1, into: &rows)
        continue
      }
      let next = path.isEmpty ? label : isList ? path + label : "\(path).\(label)"
      flatten(child.value, path: next, depth: depth + 1, into: &rows)
    }
  }

  private static func leafText(_ value: Any) -> String? {
    switch value {
    case let text as String: return text.isEmpty ? "\"\"" : text
    case let flag as Bool: return flag ? "true" : "false"
    case let number as Double: return number.isFinite ? String(format: "%.4g", number) : "—"
    case let number as Float: return number.isFinite ? String(format: "%.4g", Double(number)) : "—"
    case let date as Date: return date.formatted(date: .numeric, time: .standard)
    case let error as TelemetryError: return "unavailable: \(error)"
    case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32, is UInt64:
      return "\(value)"
    case let duration as Duration: return "\(duration)"
    default:
      let mirror = Mirror(reflecting: value)
      // Field-less enums (e.g. MemoryPressure.normal) print as their case.
      if mirror.displayStyle == .enum, mirror.children.isEmpty { return "\(value)" }
      return nil
    }
  }
}

/// Collapsed by default; opening it freezes one snapshot. "Refresh" takes a new one.
struct HeliosAllReadingsSection: View {
  @ObservedObject var model: OverviewViewModel
  @State private var expanded = false
  @State private var groups: [HeliosReadingTree.Group] = []
  @State private var capturedAt: Date?

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(capturedAt.map { "Readings at \($0.formatted(date: .omitted, time: .standard))" } ?? "")
            .font(.subheadline).foregroundStyle(.secondary)
          Spacer()
          Button("Refresh") { capture() }.controlSize(.small)
        }
        ForEach(groups) { group in
          DisclosureGroup("\(group.name) (\(group.rows.count))") {
            HeliosGroup {
              ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text(row.path).font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
                  Spacer(minLength: 12)
                  Text(row.value).font(.system(.subheadline, design: .monospaced))
                    .multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(3)
                }
                .padding(.vertical, 3)
                if index < group.rows.count - 1 { Divider() }
              }
            }
            .padding(.top, 4)
          }
        }
      }
      .padding(.top, 8)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("All readings")
        Text("Every value Helios currently reads, unprocessed. Stays on this Mac.")
          .font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .onChange(of: expanded) { open in
      if open { capture() } else { groups = [] }
    }
  }

  private func capture() {
    groups = HeliosReadingTree.groups(model.snapshot, extra: [
      ("persistentHistory", model.persistentHistory), ("ioAudit", model.ioAudit),
      ("appEnergy", model.appEnergy), ("batteryHealth", model.batteryHealth),
      ("healthEvents", model.healthCenter.events),
    ])
    capturedAt = Date()
  }
}
