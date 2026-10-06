import SwiftUI

struct HeliosStoragePage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @State private var showMaintenance = false
  @State private var showDetails = false

  var body: some View {
    let presentation = model.presentation
    let assessment = HeliosMacAssessment.storage(
      model.snapshot, now: Date(), configuration: context.preferences.healthAlerts)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      HeliosAreaHeader(
        assessment: assessment, meaning: HeliosCopy.meaning(.storage), valueCaption: "Startup disk")
      if !context.preferences.isTelemetryCollectionRequired(.storage) {
        HeliosCollectionOffNotice(
          title: "Storage monitoring is off.", module: .storage, preferences: context.preferences)
      }
      if case .success(let storage) = presentation.storage {
        if case .success(let root) = storage.rootVolume, root.totalBytes > 0 {
          HeliosCapacityBar(used: root.usedBytes, total: root.totalBytes)
        }
        HStack(alignment: .top, spacing: 20) {
          HeliosSection("SSD health") { HeliosGroup { smartRows(storage) } }
          HeliosSection("Activity") { HeliosGroup { activityRows(storage) } }
        }
      }
      HeliosChartPanel(
        metric: .disk, model: model, preferences: context.preferences, scope: .storage, height: 110)

      DisclosureGroup("Maintenance", isExpanded: $showMaintenance) {
        HeliosMaintenanceSection().padding(.top, 8)
      }
      if case .success(let storage) = presentation.storage {
        DisclosureGroup("Details", isExpanded: $showDetails) {
          HeliosFactList(rows: detailRows(storage, processes: presentation.processes)).padding(.top, 8)
        }
      }
    }
  }

  @ViewBuilder
  private func smartRows(_ storage: StorageMetrics) -> some View {
    switch storage.smartHealth {
    case .success(let smart):
      HeliosFactRow(label: "Status", value: smart.state.rawValue, detail: "NVMe SMART")
      HeliosFactRow(label: "Wear", value: "\(smart.percentageUsed) % used")
      HeliosFactRow(label: "Spare blocks", value: "\(smart.availableSparePercent) %")
      HeliosFactRow(label: "Temperature",
        value: smart.temperatureCelsius.map { TelemetryFormatting.temperature($0) } ?? "Not reported")
      HeliosFactRow(label: "Media errors", value: HeliosText.counter(smart.mediaErrors), showsDivider: false)
    case .failure(let error):
      HeliosFactRow(label: "SMART", value: HeliosText.failure(error),
        detail: storage.primaryDevice?.smartCapability.rawValue, showsDivider: false)
    }
  }

  @ViewBuilder
  private func activityRows(_ storage: StorageMetrics) -> some View {
    HeliosFactRow(label: "Reading",
      value: HeliosText.value(storage.throughput) { TelemetryFormatting.bytesPerSecond($0.readBytesPerSecond) })
    HeliosFactRow(label: "Writing",
      value: HeliosText.value(storage.throughput) { TelemetryFormatting.bytesPerSecond($0.writeBytesPerSecond) })
    HeliosFactRow(label: "Written since Helios started",
      value: HeliosText.value(storage.monitoringWrittenBytes) { TelemetryFormatting.storageBytes($0) })
    switch storage.smartHealth {
    case .success(let smart):
      HeliosFactRow(label: "Lifetime written",
        value: TelemetryFormatting.decimalBytes(smart.lifetimeWrittenBytes), showsDivider: false)
    case .failure:
      HeliosFactRow(label: "Lifetime written", value: "Unavailable", showsDivider: false)
    }
  }

  private func detailRows(_ storage: StorageMetrics, processes: MetricResult<ProcessMetrics>)
    -> [HeliosEvidence]
  {
    var rows: [HeliosEvidence] = []
    if let primary = storage.primaryDevice {
      rows.append(HeliosEvidence(label: "Startup device", value: primary.model,
        source: "\(primary.bsdName) · \(TelemetryFormatting.storageBytes(primary.capacityBytes))"))
    }
    if case .success(let rate) = storage.throughput {
      rows.append(HeliosEvidence(label: "IOPS (read / write)",
        value: "\(TelemetryFormatting.iops(rate.readIOPS)) / \(TelemetryFormatting.iops(rate.writeIOPS))"))
    }
    if case .success(let smart) = storage.smartHealth {
      rows.append(HeliosEvidence(label: "Power-on hours", value: HeliosText.counter(smart.powerOnHours)))
      rows.append(HeliosEvidence(label: "Unsafe shutdowns", value: HeliosText.counter(smart.unsafeShutdowns)))
      rows.append(HeliosEvidence(label: "Lifetime read",
        value: TelemetryFormatting.decimalBytes(smart.lifetimeReadBytes)))
    }
    for device in storage.externalPhysicalDevices {
      rows.append(HeliosEvidence(label: device.model, value: TelemetryFormatting.storageBytes(device.capacityBytes),
        source: "External · \(device.transport)"))
    }
    if case .success(let metrics) = processes, let writer = metrics.topByDiskWrite.first,
      let rate = writer.diskWriteBytesPerSecond
    {
      rows.append(HeliosEvidence(label: "Most writing", value: "\(writer.name) · \(TelemetryFormatting.bytesPerSecond(rate))",
        source: "Process accounting differs from physical disk counters"))
    }
    return rows
  }
}

/// One horizontal bar: used vs free on the startup disk.
private struct HeliosCapacityBar: View {
  let used: UInt64
  let total: UInt64

  var body: some View {
    let fraction = total > 0 ? min(1, Double(used) / Double(total)) : 0
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
          RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.8))
            .frame(width: proxy.size.width * fraction)
        }
      }
      .frame(height: 10)
      HStack {
        Text("\(TelemetryFormatting.storageBytes(used)) used")
        Spacer()
        Text("\(TelemetryFormatting.storageBytes(total >= used ? total - used : 0)) free of \(TelemetryFormatting.storageBytes(total))")
      }
      .font(.subheadline)
      .monospacedDigit()
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Startup disk")
    .accessibilityValue("\(TelemetryFormatting.percent(fraction * 100)) used, \(TelemetryFormatting.storageBytes(total >= used ? total - used : 0)) free")
  }
}

/// Explicit, read-only scans. Never automatic; cancelled when the page closes.
private struct HeliosMaintenanceSection: View {
  @StateObject private var maintenance = MaintenanceViewModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Read-only scans. Helios estimates space and lists apps; it never deletes or changes anything.")
        .font(.subheadline).foregroundStyle(.secondary)
      HStack {
        Button(maintenance.scanningCleanup ? "Scanning…" : "Scan Caches") { maintenance.scanCleanup() }
          .disabled(maintenance.scanningCleanup)
        Button(maintenance.scanningApplications ? "Scanning…" : "Scan Applications") {
          maintenance.scanApplications()
        }
        .disabled(maintenance.scanningApplications)
        if maintenance.scanningCleanup || maintenance.scanningApplications {
          ProgressView().controlSize(.small)
        }
      }
      if let error = maintenance.cleanupError {
        Text("Cache scan unavailable: \(error)").font(.subheadline).foregroundStyle(.secondary)
      }
      if let cleanup = maintenance.cleanup {
        HeliosFactList(rows: cleanup.candidates.map {
          HeliosEvidence(label: $0.label, value: TelemetryFormatting.storageBytes($0.estimatedBytes),
            source: $0.truncated ? "Partial estimate" : nil)
        })
      }
      if let error = maintenance.applicationsError {
        Text("Application scan unavailable: \(error)").font(.subheadline).foregroundStyle(.secondary)
      }
      if let apps = maintenance.applicationsPresentation {
        HeliosFactList(rows: [
          HeliosEvidence(label: "Apple silicon", value: "\(apps.appleSiliconCount)"),
          HeliosEvidence(label: "Universal", value: "\(apps.universalCount)"),
          HeliosEvidence(label: "Intel only", value: "\(apps.intelCount)", source: "Runs through Rosetta"),
        ] + apps.largestFirst.prefix(5).map {
          HeliosEvidence(label: $0.name,
            value: $0.estimatedSizeBytes.map(TelemetryFormatting.storageBytes) ?? "Not measured")
        })
      }
    }
    .onDisappear { maintenance.cancelScans() }
  }
}
