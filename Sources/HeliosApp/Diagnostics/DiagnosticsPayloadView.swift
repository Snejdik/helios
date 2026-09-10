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

struct DiagnosticsPayloadView: View {
  let title: String
  let explanation: String
  let payload: FrozenDiagnosticsPayload
  var sendTitle = "Send report"
  var sending = false
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
        if let onRegenerate { Button("Regenerate preview", action: onRegenerate) }
        if let onSend {
          Button(sendTitle, action: onSend)
            .buttonStyle(.borderedProminent)
            .disabled(sending || payload.isExpired())
        }
      }
    }
    .padding(20)
    .frame(minWidth: 620, minHeight: 460)
  }
}
