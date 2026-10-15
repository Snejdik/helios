import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The command palette (PLAN_0_3_0 M6.2): a global shortcut (⌃⌥⌘Space) registered with
/// Carbon's RegisterEventHotKey, which needs no Accessibility permission, opens a small
/// floating panel to jump to a page, ask a question or run an action. Items run through
/// the same helios:// commands and action registry as everything else.
@MainActor
final class HeliosCommandPalette: ObservableObject {
  static let shared = HeliosCommandPalette()
  static let enabledKey = "HeliosCommandPalette.enabled"
  static let shortcutLabel = "⌃⌥⌘Space"

  @Published private(set) var enabled: Bool
  /// Another app already owns the shortcut; Settings says so instead of a silent switch.
  @Published private(set) var registrationFailed = false
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var panel: NSPanel?

  private init() {
    enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
  }

  func start() { if enabled { register() } }

  func setEnabled(_ on: Bool) {
    enabled = on
    UserDefaults.standard.set(on, forKey: Self.enabledKey)
    on ? register() : unregister()
  }

  private func register() {
    guard hotKey == nil else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      DispatchQueue.main.async { HeliosCommandPalette.shared.toggle() }
      return noErr
    }, 1, &spec, nil, &handler)
    let id = EventHotKeyID(signature: OSType(0x484C_5350), id: 1) // "HLSP"
    // ⌃⌥Space belongs to macOS (next input source), so the palette adds ⌘.
    let status = RegisterEventHotKey(
      UInt32(kVK_Space), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    registrationFailed = status != noErr
    if registrationFailed {
      hotKey = nil
      if let handler { RemoveEventHandler(handler) }
      handler = nil
    }
  }

  private func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
    registrationFailed = false
    panel?.close()
  }

  func toggle() {
    if let panel, panel.isVisible { panel.close(); return }
    show()
  }

  func show() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    panel.contentViewController = NSHostingController(rootView: HeliosPaletteView(close: { [weak panel] in panel?.close() }))
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = true
    panel.isReleasedWhenClosed = false
    panel.title = "Helios"
    return panel
  }
}

struct HeliosPaletteItem: Identifiable, Equatable {
  enum Run: Equatable {
    case url(String)
    case quit(pid: Int32, name: String)
  }

  let id: String
  let title: String
  let symbol: String
  let run: Run

  /// Every item, in a stable order; filtering is a plain case-insensitive match.
  @MainActor static func all(processes: [ProcessActivity]) -> [Self] {
    var items: [Self] = []
    for lens in HeliosLens.allCases {
      items.append(Self(id: "why.\(lens.rawValue)", title: lens.question, symbol: "questionmark.circle",
                        run: .url("helios://why/\(lens.rawValue)")))
    }
    for page in HeliosPage.allCases {
      items.append(Self(id: "page.\(page.rawValue)", title: "Open \(page.title)", symbol: page.symbol,
                        run: .url("helios://open/\(page.rawValue)")))
    }
    items += [
      Self(id: "awake.60", title: "Keep Awake for 1 Hour", symbol: "cup.and.saucer", run: .url("helios://keep-awake?minutes=60")),
      Self(id: "awake.stop", title: "Stop Keep Awake", symbol: "cup.and.saucer", run: .url("helios://keep-awake/stop")),
      Self(id: "net", title: "Check Network", symbol: "network", run: .url("helios://network-check")),
      Self(id: "fans.system", title: "Return Fans to macOS", symbol: "fan", run: .url("helios://fans/system")),
    ]
    for process in processes.prefix(5) where process.pid != ProcessInfo.processInfo.processIdentifier {
      let name = HeliosDiagnosisNames.app(process)
      items.append(Self(id: "quit.\(process.pid)", title: "Quit \(name)…", symbol: "xmark.circle",
                        run: .quit(pid: process.pid, name: name)))
    }
    return items
  }

  static func filter(_ items: [Self], query: String) -> [Self] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return items }
    return items.filter { item in words.allSatisfy { item.title.lowercased().contains($0) } }
  }
}

private struct HeliosPaletteView: View {
  let close: () -> Void
  @State private var query = ""
  @FocusState private var focused: Bool

  var body: some View {
    let processes = (try? HeliosAppState.latestSnapshot.processes.result.get())?.topByCPU ?? []
    let items = HeliosPaletteItem.filter(HeliosPaletteItem.all(processes: processes), query: query)
    VStack(alignment: .leading, spacing: 8) {
      TextField("Ask Helios or type a command", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(.title3)
        .focused($focused)
        .onSubmit { if let first = items.first { run(first) } }
      List(items) { item in
        Button { run(item) } label: { Label(item.title, systemImage: item.symbol) }
          .buttonStyle(.plain)
      }
      .listStyle(.plain)
    }
    .padding(14)
    .frame(width: 520, height: 360)
    .onAppear { focused = true }
    .onExitCommand(perform: close)
  }

  private func run(_ item: HeliosPaletteItem) {
    close()
    switch item.run {
    case .url(let text): if let url = URL(string: text) { HeliosAutomationCenter.shared.handle(url) }
    case .quit(let pid, let name): HeliosActionRegistry.quit(pid: pid, name: name)
    }
  }
}

/// The latest telemetry snapshot for surfaces that live outside a window (palette, status
/// file). Updated by the app on every telemetry publication.
@MainActor
enum HeliosAppState {
  static var latestSnapshot = TelemetrySnapshot()
}

/// `helios status` for the command line (PLAN_0_3_0 M6.5): while switched on, Helios writes
/// a small summary every 10 seconds to ~/Library/Application Support/Helios/status.json
/// (owner-only). Off by default, so nothing is written unless asked for.
@MainActor
final class HeliosStatusFile: ObservableObject {
  static let shared = HeliosStatusFile()
  static let enabledKey = "HeliosStatusFile.enabled"
  @Published private(set) var enabled: Bool
  private var lastWrite: Date?

  private init() { enabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }

  static var url: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("status.json")
  }

  func setEnabled(_ on: Bool) {
    enabled = on
    UserDefaults.standard.set(on, forKey: Self.enabledKey)
    if on { lastWrite = nil; observe(HeliosAppState.latestSnapshot) } else { try? FileManager.default.removeItem(at: Self.url) }
  }

  func observe(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    guard enabled, lastWrite.map({ now.timeIntervalSince($0) >= 10 }) ?? true else { return }
    lastWrite = now
    guard let data = try? JSONSerialization.data(
      withJSONObject: HeliosStatusSummary.make(snapshot, now: now, keepAwake: HeliosKeepAwake.shared.isActive),
      options: [.prettyPrinted, .sortedKeys])
    else { return }
    let folder = Self.url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Owner-only from the first byte: write a 0600 temporary file, then rename it into place.
    let temporary = folder.appendingPathComponent(".status-\(UUID().uuidString).json")
    guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                         attributes: [.posixPermissions: 0o600])
    else { return }
    if rename(temporary.path, Self.url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
  }
}
