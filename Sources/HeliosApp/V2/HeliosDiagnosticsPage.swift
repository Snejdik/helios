import SwiftUI

/// A finding: issue → likely cause (only when evidence supports one) → evidence → action.
struct HeliosFinding: Identifiable, Equatable {
  let area: HeliosArea
  let status: HeliosStatus
  let title: String
  let summary: String
  let likelyCause: String?
  let evidence: [HeliosEvidence]
  let action: String
  var id: HeliosArea { area }

  /// Deterministic: built only from the assessment and the shared snapshot.
  static func findings(_ assessment: HeliosMacAssessment, snapshot: TelemetrySnapshot, now: Date = Date())
    -> [HeliosFinding]
  {
    assessment.areas.enumerated().filter { $0.element.status.isProblem }
      // Worst first; ties keep the fixed area order.
      .sorted { ($0.element.status.rank, -$0.offset) > ($1.element.status.rank, -$1.offset) }
      .map(\.element)
      .map { area in
        HeliosFinding(
          area: area.area, status: area.status, title: title(area), summary: area.explanation,
          likelyCause: likelyCause(area, snapshot: snapshot, now: now), evidence: area.evidence,
          action: action(area))
      }
  }

  private static func title(_ area: HeliosAreaAssessment) -> String {
    switch area.area {
    case .performance: area.status == .critical ? "Critical memory pressure" : "Elevated memory pressure"
    case .thermals: area.status == .critical ? "Very high temperature" : "High temperature"
    case .battery: "Battery condition"
    case .storage: "Storage condition"
    }
  }

  /// Correlation stated as correlation. Only the largest consumer is named.
  private static func likelyCause(_ area: HeliosAreaAssessment, snapshot: TelemetrySnapshot, now: Date)
    -> String?
  {
    guard case .success(let processes) = TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now)
    else { return nil }
    switch area.area {
    case .performance:
      guard let top = processes.topByMemory.first else { return nil }
      let identity = HeliosAppIdentity.of(top)
      return "\(identity.name) is using the most memory (\(TelemetryFormatting.storageBytes(top.physicalFootprintBytes)))."
    case .thermals:
      guard let leader = HeliosMacAssessment.mostActiveProcess(snapshot, now: now) else { return nil }
      return "Most active right now: \(leader). Heavy work raises temperature while it runs."
    case .battery, .storage:
      return nil
    }
  }

  private static func action(_ area: HeliosAreaAssessment) -> String {
    switch area.reason {
    case .memoryPressure?:
      "Quit apps you are not using, starting with those using the most memory."
    case .thermalPressure?, .hotSensor?:
      area.status == .critical
        ? "Pause heavy work and let your Mac cool down. Keep its vents unobstructed."
        : "Expected during heavy work. If it persists while idle, check that vents are not blocked."
    case .batteryCapacity?:
      "Capacity declines with age. System Settings › Battery shows Apple’s service recommendation."
    case .batteryTemperature?:
      "Move your Mac somewhere cooler and avoid charging it while it is hot."
    case .lowDiskSpace?:
      "Free up space: empty the Trash, remove large files, or open System Settings › General › Storage."
    case .ssdHealth?, .ssdMediaErrors?:
      "Back up your data now. If the condition persists, contact Apple Support."
    case .ssdTemperature?:
      "Heavy disk activity warms the SSD. If it stays hot while idle, let your Mac cool down."
    case nil:
      "Keep an eye on this area."
    }
  }
}

struct HeliosDiagnosticsPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel

  var body: some View {
    let assessment = HeliosMacAssessment.evaluate(
      model.snapshot, configuration: context.preferences.healthAlerts)
    let findings = HeliosFinding.findings(assessment, snapshot: model.snapshot)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      HeliosSection("Findings") {
        if findings.isEmpty {
          HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityHidden(true)
            Text(assessment.overall.isJudgement
              ? "No findings. Helios keeps checking performance, thermals, battery and storage."
              : "No findings yet. Helios is still waiting for some readings.")
              .foregroundStyle(.secondary)
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(findings) { HeliosFindingView(finding: $0) }
          }
        }
      }

      HeliosSection("What Helios can see") {
        HeliosSourceList(context: context, snapshot: model.snapshot)
      }

      if let service = context.service {
        HeliosSection("Helper and fan control") {
          VStack(alignment: .leading, spacing: 10) {
            HeliosHelperStatus(service: service, client: service.client,
              preflight: model.presentation.fanOwnershipPreflight)
            if service.state != .installed {
              HStack {
                Button(service.state == .requiresApproval ? "Approve Helper…" : "Install Helper…") {
                  context.actions.openSettingsRoute(.fans)
                }
                Spacer(minLength: 0)
              }
            }
          }
        }
      }

      HeliosSection("Support") {
        HStack(spacing: 12) {
          Button("Copy System Snapshot", action: context.actions.copySystemSnapshot)
          Button("Beta Diagnostics…") { context.actions.openSettingsRoute(.privacy) }
        }
        Text("The snapshot contains only versions, model family and source states — no names, paths, network identifiers or readings.")
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct HeliosFindingView: View {
  let finding: HeliosFinding
  @State private var showEvidence = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(finding.title).font(.headline)
        Spacer()
        HeliosStatusLabel(status: finding.status)
      }
      Text(finding.summary).fixedSize(horizontal: false, vertical: true)
      if let cause = finding.likelyCause {
        labeled("Likely contributor", cause)
      }
      labeled("What you can do", finding.action)
      DisclosureGroup("Evidence", isExpanded: $showEvidence) {
        HeliosFactList(rows: finding.evidence).padding(.top, 6)
      }
    }
    .padding(14)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: HeliosDesign.groupCornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: HeliosDesign.groupCornerRadius)
        .strokeBorder(HeliosDesign.color(finding.status).opacity(0.5), lineWidth: 1))
  }

  private func labeled(_ label: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.subheadline).foregroundStyle(.secondary)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Per-source observation state from the canonical snapshot, plus collection choice.
private struct HeliosSourceList: View {
  let context: HeliosContext
  let snapshot: TelemetrySnapshot
  @State private var expanded: Bool?

  var body: some View {
    let rows = sources
    let readable = rows.filter { $0.status == .normal }.count
    let collected = rows.filter { $0.status != .notPresent }.count
    // Calm when everything is readable; open by default when something is not.
    let isExpanded = Binding(get: { expanded ?? (readable < collected) }, set: { expanded = $0 })
    DisclosureGroup(isExpanded: isExpanded) {
      list(rows).padding(.top, 6)
    } label: {
      Text("\(readable) of \(collected) collected sources readable")
    }
  }

  private func list(_ rows: [Source]) -> some View {
    HeliosGroup {
      ForEach(Array(rows.enumerated()), id: \.element.title) { index, row in
        HStack(alignment: .firstTextBaseline) {
          Text(row.title)
          Spacer()
          if let note = row.note {
            Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.tail)
          }
          HeliosStatusLabel(status: row.status,
            text: row.status == .normal ? "Available" : row.status == .notPresent ? "Off" : nil)
        }
        .padding(.vertical, 6)
        .help(row.note ?? row.status.label)
        if index < rows.count - 1 { Divider() }
      }
    }
  }

  private struct Source {
    let title: String
    let status: HeliosStatus
    let note: String?
  }

  private var sources: [Source] {
    let now = Date()
    func row<V>(_ title: String, _ sample: MetricSample<V>, maxAge: TimeInterval,
      module: HeliosTelemetryModule?) -> Source
    {
      if let module, !context.preferences.isTelemetryCollectionRequired(module) {
        return Source(title: title, status: .notPresent, note: "Not collected")
      }
      let observation = TelemetryFormatting.observation(sample, maxAge: maxAge, now: now)
      switch observation.state {
      case .available: return Source(title: title, status: .normal, note: nil)
      case .waiting: return Source(title: title, status: .waiting, note: nil)
      case .stale:
        return Source(title: title, status: .stale(age: now.timeIntervalSince(sample.capturedAt)), note: nil)
      case .unavailable:
        if case .failure(let error) = sample.result {
          return Source(title: title, status: .unavailable, note: error.localizedDescription)
        }
        return Source(title: title, status: .unavailable, note: nil)
      }
    }
    return [
      row("CPU", snapshot.cpu, maxAge: 5, module: .cpu),
      row("Memory", snapshot.memory, maxAge: 5, module: .memory),
      row("GPU", snapshot.gpu, maxAge: 5, module: .gpu),
      row("Temperature sensors", snapshot.thermals, maxAge: 6, module: nil),
      row("Fans", snapshot.fans, maxAge: 5, module: .fans),
      row("System power", snapshot.systemPower, maxAge: 5, module: .power),
      row("Battery", snapshot.battery, maxAge: 20, module: .battery),
      row("Storage", snapshot.storage, maxAge: 10, module: .storage),
      row("Processes", snapshot.processes, maxAge: 12, module: .processes),
      row("Network", snapshot.network, maxAge: 5, module: .network),
      row("Wi-Fi", snapshot.wifi, maxAge: 15, module: .wifi),
      row("Devices", snapshot.displays, maxAge: 90, module: .devices),
      row("System", snapshot.system, maxAge: 30, module: nil),
    ]
  }
}

private struct HeliosHelperStatus: View {
  @ObservedObject var service: DaemonService
  @ObservedObject var client: DaemonClient
  let preflight: MetricResult<FanOwnershipPreflightSnapshot>

  var body: some View {
    HeliosGroup {
      HeliosFactRow(label: "Helper", value: service.state.rawValue.capitalized,
        detail: "Needed only for fan control")
      HeliosFactRow(label: "Connection", value: client.state.rawValue)
      HeliosFactRow(label: "Fan control", value: client.fanControlAvailable ? "Available" : "Unavailable",
        detail: client.fanControlAvailable ? nil : client.fanDetail)
      HeliosFactRow(label: "Hardware check", value: HeliosText.value(preflight) { $0.summary },
        detail: "Read-only comparison with the validated fan profile", showsDivider: false)
    }
  }
}
