import SwiftUI

struct DaemonServiceCard: View {
  @ObservedObject var service: DaemonService
  @ObservedObject var client: DaemonClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Helper Service", systemImage: "bolt.horizontal.circle")
          .font(.system(size: 13, weight: .bold))
        Spacer()
        Text(service.state.rawValue).font(.system(size: 10, weight: .medium))
          .foregroundStyle(service.state == .installed ? .green : .secondary)
      }
      HStack {
        Text("Connection").foregroundStyle(.secondary)
        Spacer()
        Text(client.state.rawValue)
      }.font(.system(size: 11))
      HStack {
        Text("Boot registration").foregroundStyle(.secondary)
        Spacer()
        Text(
          service.state == .installed || service.state == .requiresApproval
            ? "Registered (RunAtLoad)" : "Not registered")
      }.font(.system(size: 11))
      if client.state == .connected {
        Text(
          client.fanState == .system ? "Heartbeat active · No Helios override" : "Heartbeat active"
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if service.state == .requiresApproval && service.message == nil {
        Text("Approve Helios in Login Items & Extensions to let the helper run.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if let message = service.message ?? client.detail {
        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
          .help(service.errorDetail ?? message)
          .fixedSize(horizontal: false, vertical: true)
      }
      Divider().opacity(0.5)
      HStack {
        if service.state == .missing {
          Button("Install Helper") { service.install() }
        } else if service.state == .requiresApproval {
          Button("Open System Settings") { service.openApprovalSettings() }
        } else if service.state == .installed {
          Button("Reinstall") { Task { await service.reinstall() } }
        }
        Spacer()
        if service.state == .installed || service.state == .requiresApproval {
          Button("Uninstall") { Task { await service.uninstall() } }
        }
        Button {
          service.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh helper status")
      }
      .font(.system(size: 11))
      .disabled(service.busy)
      .accessibilityLabel(
        service.busy ? "Updating helper registration" : "Helper registration actions")
    }
    .padding(12)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(
        Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5))
  }
}
