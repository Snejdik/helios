import Combine
import Foundation

/// Derived Activity timeline for one open Helios surface. Recomputes only when
/// the 30-second persistent history or the health event log publishes, never on
/// the 1 Hz snapshot. Owned by the window/popover and released with it.
@MainActor
final class HeliosActivityFeed: ObservableObject {
  @Published private(set) var events: [HeliosActivityEvent] = []
  private var subscriptions: Set<AnyCancellable> = []

  init(model: OverviewViewModel) {
    let center = model.healthCenter
    let activeIDs = center.$issues.map { Set($0.map(\.id)) }.removeDuplicates()
    Publishers.CombineLatest3(model.$persistentHistory, center.$events, activeIDs)
      .map { history, records, activeIssueIDs in
        HeliosActivityTimeline.events(
          health: records, history: history.points, activeIssueIDs: activeIssueIDs)
      }
      .removeDuplicates()
      .sink { [weak self] events in self?.events = events }
      .store(in: &subscriptions)
  }

  /// A fixed timeline for deterministic fixtures; no subscriptions.
  init(fixedEvents: [HeliosActivityEvent]) {
    events = fixedEvents
  }

  func recent(_ count: Int) -> ArraySlice<HeliosActivityEvent> {
    events.filter { $0.kind != .peak }.prefix(count)
  }

  func markers(for metric: HeliosChartMetric, range: HeliosGraphRange, now: Date = Date())
    -> [HeliosChartMarker]
  {
    HeliosActivityTimeline.markers(
      events, metric: metric, from: now.addingTimeInterval(-range.seconds), to: now)
  }
}
