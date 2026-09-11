import AppKit
import SwiftUI

@MainActor
final class DiagnosticsManualApproval: ObservableObject {
  @Published private(set) var payload: FrozenDiagnosticsPayload?
  @Published private(set) var approvedGeneration: UInt64?
  private var generation: UInt64 = 0

  var preview: String { payload?.preview ?? "" }
  var hasPayload: Bool { payload != nil }

  func replace<T: Encodable>(
    with report: T,
    reportType: DiagnosticsReportType,
    now: Date = Date()
  ) throws {
    generation &+= 1
    approvedGeneration = nil
    payload = try DiagnosticsPayloadEncoder.freeze(
      report, reportType: reportType, now: now, generation: generation)
  }

  func setFrozen(_ frozen: FrozenDiagnosticsPayload) {
    generation &+= 1
    approvedGeneration = nil
    payload = FrozenDiagnosticsPayload(
      data: frozen.data, reportType: frozen.reportType, createdAt: frozen.createdAt,
      generation: generation)
  }

  func approve(at date: Date = Date()) -> FrozenDiagnosticsPayload? {
    guard let payload, !payload.isExpired(at: date) else {
      approvedGeneration = nil
      return nil
    }
    approvedGeneration = payload.generation
    return payload
  }

  func approvedPayload(at date: Date = Date()) -> FrozenDiagnosticsPayload? {
    guard let payload, approvedGeneration == payload.generation, !payload.isExpired(at: date)
    else { return nil }
    return payload
  }

  func invalidate() {
    approvedGeneration = nil
    payload = nil
  }
}

struct DiagnosticsCompatibilityConsentView: View {
  let generating: Bool
  let status: String?
  let onCancel: () -> Void
  let onGenerate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Create compatibility report").font(.system(size: 20, weight: .semibold))
      Text(
        "Helios will run a bounded read-only hardware probe. Generation stays on this Mac and makes no network request. You will see the complete JSON before a separate Send action."
      )
      .foregroundStyle(.secondary)

      GroupBox("Read-only categories") {
        VStack(alignment: .leading, spacing: 8) {
          Label("Thermal SMC key, type and size metadata", systemImage: "thermometer.medium")
          Label("Safely decoded finite temperatures", systemImage: "waveform.path.ecg")
          Label("Fan count, available RPM ranges and one actual-RPM reading", systemImage: "fan")
          Label(
            "Coarse provider failures and numeric driver codes",
            systemImage: "wrench.and.screwdriver")
        }
        .padding(4)
      }
      Text(
        "It never collects raw SMC bytes, serial numbers, identifiers, files, process names, logs, fan commands, or write capability. The privileged helper is not used."
      )
      .font(.system(size: 10.5)).foregroundStyle(.secondary)
      if let status {
        Text(status).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel).disabled(generating)
        Button("Generate preview", action: onGenerate)
          .buttonStyle(.borderedProminent)
          .disabled(generating)
      }
    }
    .padding(22)
    .frame(width: 560)
    .interactiveDismissDisabled(generating)
  }
}

struct DiagnosticsPayloadView: View {
  let title: String
  let explanation: String
  let payload: FrozenDiagnosticsPayload
  var sendTitle = "Send report"
  var sending = false
  var sendDisabled = false
  var status: String?
  var onSend: (() -> Void)?
  var onRegenerate: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 20, weight: .semibold))
        Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary)
      }

      ScrollView([.horizontal, .vertical]) {
        Text(payload.preview)
          .font(.system(size: 10.5, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
      }
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))

      if let status {
        Text(status).font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
      }

      HStack {
        Text("This exact UTF-8 JSON is the complete request body.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        Spacer()
        Button("Copy JSON") {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(payload.preview, forType: .string)
        }
        if let onRegenerate { Button("Regenerate preview", action: onRegenerate) }
        if let onSend {
          Button(sendTitle, action: onSend)
            .buttonStyle(.borderedProminent)
            .disabled(sending || sendDisabled || payload.isExpired())
        }
      }
    }
    .padding(20)
    .frame(minWidth: 620, minHeight: 460)
  }
}
