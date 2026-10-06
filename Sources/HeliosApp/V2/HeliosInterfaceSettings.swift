import SwiftUI

/// Settings › Modules › Popover (Helios interface).
struct HeliosPopoverSettings: View {
  @ObservedObject var interface: HeliosInterfacePreferences

  var body: some View {
    Form {
      Section {
        ForEach(HeliosPopoverSection.allCases) { section in
          HStack {
            Toggle(section.title, isOn: Binding(
              get: { interface.isPopoverSectionEnabled(section) },
              set: { interface.setPopoverSection(section, enabled: $0) }))
            Spacer()
            if interface.isPopoverSectionEnabled(section) {
              Button { interface.movePopoverSection(section, by: -1) } label: {
                Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
              .disabled(interface.popoverSections.first == section)
              Button { interface.movePopoverSection(section, by: 1) } label: {
                Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
              .disabled(interface.popoverSections.last == section)
            }
          }
        }
      } header: {
        Text("Below the summary")
      } footer: {
        Text("The summary of your Mac is always shown first. Cooling appears only on Macs with a fan.")
          .foregroundStyle(.secondary)
      }
      Section("Order") {
        Text(interface.popoverSections.isEmpty
          ? "Summary only"
          : (["Summary"] + interface.popoverSections.map(\.title)).joined(separator: " · "))
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// Settings › Modules › Window (Helios interface).
struct HeliosWindowSettings: View {
  @ObservedObject var interface: HeliosInterfacePreferences

  var body: some View {
    Form {
      Section {
        ForEach(HeliosPage.allCases.filter { $0 != .overview }) { page in
          Toggle(isOn: Binding(
            get: { !interface.hiddenPages.contains(page) },
            set: { interface.setPage(page, visible: $0) })
          ) {
            Label(page.title, systemImage: page.symbol)
          }
        }
      } header: {
        Text("Sidebar")
      } footer: {
        Text("Hiding a page changes only the sidebar; Helios keeps monitoring. Overview is always shown.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
