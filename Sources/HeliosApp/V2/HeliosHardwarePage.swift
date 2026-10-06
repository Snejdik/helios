import SwiftUI

struct HeliosHardwarePage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @State private var showCapabilities = false
  @State private var showRawSMC = false

  var body: some View {
    let presentation = model.presentation
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      thisMac(presentation)

      HeliosSection("Connected") {
        if !context.preferences.isTelemetryCollectionRequired(.devices) {
          HeliosCollectionOffNotice(
            title: "Device monitoring is off.", module: .devices, preferences: context.preferences)
        } else {
          let rows = HeliosDeviceRows.rows(presentation)
          if rows.isEmpty {
            HeliosEmptyState(symbol: "cable.connector", title: "Reading connected devices…")
          } else {
            HeliosGroup {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 10) {
                  Image(systemName: row.symbol).foregroundStyle(.secondary).frame(width: 18)
                    .accessibilityHidden(true)
                  Text(row.name).lineLimit(1)
                  Spacer()
                  Text(row.detail).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { Divider() }
              }
            }
          }
        }
      }

      DisclosureGroup("What Helios can read on this Mac", isExpanded: $showCapabilities) {
        HeliosCapabilityList(snapshot: model.snapshot).padding(.top, 8)
      }
      DisclosureGroup("Raw SMC inventory", isExpanded: $showRawSMC) {
        HeliosRawSMCSection(model: model).padding(.top, 8)
      }
    }
  }

  /// What this Mac is, in the order people ask: chip, cores, graphics, memory, system.
  @ViewBuilder
  private func thisMac(_ p: OverviewPresentation) -> some View {
    switch p.system {
    case .success(let system):
      HeliosSection("This Mac") {
        HeliosFactList(rows: [
          HeliosEvidence(label: "Chip", value: HeliosText.value(system.chipName) { $0 }),
          HeliosEvidence(label: "Cores", value: coresText(p.cpu, logical: system.logicalProcessorCount)),
          HeliosEvidence(label: "Graphics", value: graphicsText(p.gpu)),
          // Installed RAM is marketed in binary units: 16 GB = 16 GiB.
          HeliosEvidence(label: "Memory",
            value: String(format: "%.0f GB", Double(system.physicalMemoryBytes) / 1_073_741_824)),
          // The version string already ends with its build, e.g. "Version 27.0.1 (Build 26A434)".
          HeliosEvidence(label: "macOS", value: system.osVersion),
          HeliosEvidence(label: "Model", value: HeliosText.value(system.modelIdentifier) { $0 }),
          HeliosEvidence(label: "Uptime", value: TelemetryFormatting.duration(system.uptimeSeconds)),
        ])
      }
    case .failure(let error):
      HeliosStatusLabel(status: error == .warmingUp ? .waiting : .unavailable, prominent: true)
    }
  }

  private func coresText(_ cpu: MetricResult<CPUMetrics>, logical: Int) -> String {
    guard case .success(let metrics) = cpu, let split = HeliosCPUPage.coreSplitText(metrics)
    else { return "\(logical) logical" }
    return split
  }

  private func graphicsText(_ gpu: MetricResult<GPUMetrics>) -> String {
    guard case .success(let metrics) = gpu else { return "—" }
    let model = HeliosText.value(metrics.model) { $0 }
    if case .success(let cores) = metrics.coreCount { return "\(model) · \(cores) cores" }
    return model
  }
}

private struct HeliosDeviceRow: Identifiable {
  let id: String
  let symbol: String
  let name: String
  let detail: String
}

private enum HeliosDeviceRows {
  static func rows(_ p: OverviewPresentation) -> [HeliosDeviceRow] {
    var rows: [HeliosDeviceRow] = []
    if case .success(let displays) = p.displays {
      for display in displays.displays where display.active {
        let rate = display.refreshRateHz.map { String(format: " @ %.0f Hz", $0) } ?? ""
        rows.append(HeliosDeviceRow(
          id: "display-\(display.displayID)", symbol: display.builtIn ? "laptopcomputer" : "display",
          name: display.builtIn ? "Built-in display" : "Display",
          detail: "\(display.pixelWidth)×\(display.pixelHeight)\(rate)"))
      }
    }
    if case .success(let bluetooth) = p.bluetooth {
      for device in bluetooth.devices where device.connected {
        rows.append(HeliosDeviceRow(
          id: "bt-\(device.id)", symbol: "wave.3.right", name: device.name,
          detail: device.battery.mainPercent.map { "Bluetooth · \($0) %" } ?? "Bluetooth"))
      }
    }
    if case .success(let usb) = p.usb {
      for device in usb.devices {
        rows.append(HeliosDeviceRow(
          id: "usb-\(device.registryID)", symbol: "cable.connector", name: device.product,
          detail: device.vendor.map { "USB · \($0)" } ?? "USB"))
      }
    }
    if case .success(let audio) = p.audio, let id = audio.defaultOutputDeviceID,
      let output = audio.devices.first(where: { $0.objectID == id })
    {
      rows.append(HeliosDeviceRow(
        id: "audio-\(id)", symbol: "speaker.wave.2", name: output.name, detail: "Sound output"))
    }
    return rows
  }
}

/// What Helios can read here, from the shared capability evaluation.
struct HeliosCapabilityList: View {
  let snapshot: TelemetrySnapshot

  var body: some View {
    let report = CapabilityEvaluator.evaluate(snapshot)
    VStack(alignment: .leading, spacing: 6) {
      Text("\(report.availableCount) of \(report.totalCount) sources readable right now.")
        .font(.subheadline).foregroundStyle(.secondary)
      HeliosGroup {
        ForEach(Array(report.items.enumerated()), id: \.element.id) { index, item in
          HStack(alignment: .firstTextBaseline) {
            Text(item.title)
            Spacer()
            HeliosStatusLabel(status: status(item.state),
              text: item.state == .available ? "Available" : nil)
          }
          .padding(.vertical, 6)
          .help(item.detail)
          if index < report.items.count - 1 { Divider() }
        }
      }
    }
  }

  private func status(_ state: CapabilityItem.State) -> HeliosStatus {
    switch state {
    case .available: .normal
    case .unavailable: .unavailable
    case .warming: .waiting
    }
  }
}

/// Explicit, on-demand raw SMC numeric inventory. Values are unitless.
private struct HeliosRawSMCSection: View {
  @ObservedObject var model: OverviewViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Every numeric SMC key Helios can read, without interpretation. Apple does not document most of these keys; values are shown raw and never used for decisions.")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(model.smcNumericLoading ? "Reading…" : "Read Inventory") {
          model.loadSMCNumericInventory()
        }
        .disabled(model.smcNumericLoading)
        if model.smcNumericLoading { ProgressView().controlSize(.small) }
      }
      if let sample = model.smcNumericSample {
        switch sample.result {
        case .success(let inventory):
          Text("\(inventory.readings.count) keys\(inventory.truncated ? " (truncated)" : "") · \(inventory.failures.count) unreadable · read \(TelemetryFormatting.ageSeconds(since: sample.capturedAt)) ago")
            .font(.subheadline).foregroundStyle(.secondary)
          Table(inventory.readings) {
            TableColumn("Key", value: \.key)
            TableColumn("Type", value: \.type)
            TableColumn("Raw value") { reading in
              Text(String(format: "%.6g", reading.value)).monospacedDigit()
            }
          }
          .frame(height: 240)
        case .failure(let error):
          Text("Inventory unavailable: \(error.localizedDescription)").foregroundStyle(.secondary)
        }
      }
    }
    .onDisappear { model.cancelSMCNumericInventory() }
  }
}
