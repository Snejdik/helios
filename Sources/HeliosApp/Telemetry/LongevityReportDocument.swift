import Foundation

/// The weekly health report as a self-contained HTML file (also the source of the PDF).
/// Written only when the user exports it; never sent anywhere. No computer or user name.
enum LongevityReportDocument {
  static func html(_ report: LongevityReport, machine: String, period: DateInterval) -> String {
    let date = DateFormatter()
    date.dateStyle = .medium
    date.timeStyle = .none
    var body = """
      <h1>Mac health report</h1>
      <p class="meta">\(escape(machine)) · \(escape(date.string(from: period.start))) – \(escape(date.string(from: period.end)))</p>
      <div class="overall \(css(report.overall))">
        <div class="grade">\(escape(report.overall?.title ?? "Learning"))</div>
        <div>\(escape(report.overallSummary))</div>
      </div>
      """
    for area in report.areas {
      body += "\n<section>\n<h2>\(escape(area.kind.title)) <span class=\"chip \(css(area.grade))\">\(escape(area.grade?.title ?? "Not enough data"))</span></h2>"
      body += "\n<p>\(escape(area.summary))</p>"
      if !area.facts.isEmpty {
        body += "\n<table>"
        for fact in area.facts {
          let detail = fact.detail.map { "<div class=\"detail\">\(escape($0))</div>" } ?? ""
          body += "\n<tr><th>\(escape(fact.label))\(detail)</th><td>\(escape(fact.value))</td></tr>"
        }
        body += "\n</table>"
      }
      if let estimate = area.estimate { body += "\n<p class=\"estimate\">\(escape(estimate))</p>" }
      if let advice = area.advice { body += "\n<p class=\"advice\">\(escape(advice))</p>" }
      body += "\n</section>"
    }
    body += """

      <p class="foot">Made by Helios from \(report.recordedDays) day\(report.recordedDays == 1 ? "" : "s") of history kept on this Mac. Projections are estimates. Helios cannot see the room temperature or how the Mac is used away from it.</p>
      """
    return """
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8">
      <title>Mac health report</title>
      <style>
      body { font: 13px -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; max-width: 680px; margin: 32px auto; padding: 0 16px; }
      h1 { font-size: 22px; margin: 0 0 4px; }
      h2 { font-size: 15px; margin: 22px 0 6px; }
      .meta, .foot, .detail { color: #6e6e73; }
      .detail { font-size: 11px; font-weight: normal; }
      .overall { border-radius: 10px; padding: 12px 14px; margin: 16px 0; background: #f2f2f7; }
      .overall .grade { font-size: 18px; font-weight: 600; }
      .chip { font-size: 11px; font-weight: 600; border-radius: 6px; padding: 2px 7px; background: #e5e5ea; vertical-align: middle; }
      .excellent .grade, .chip.excellent { color: #1f7a35; }
      .good .grade, .chip.good { color: #0a5bb5; }
      .attention .grade, .chip.attention { color: #b25000; }
      table { border-collapse: collapse; width: 100%; }
      th, td { text-align: left; padding: 5px 0; border-bottom: 1px solid #e5e5ea; vertical-align: top; }
      th { font-weight: normal; width: 60%; }
      td { font-variant-numeric: tabular-nums; }
      .estimate { color: #6e6e73; font-style: italic; }
      .advice { border-left: 3px solid #b25000; padding-left: 10px; }
      </style></head>
      <body>
      \(body)
      </body></html>
      """
  }

  /// A one-line weekly summary for the optional notification.
  static func notificationBody(_ report: LongevityReport) -> String {
    guard let overall = report.overall else { return report.overallSummary }
    return "\(overall.title). \(report.overallSummary)"
  }

  private static func css(_ grade: LongevityGrade?) -> String {
    switch grade {
    case .excellent: "excellent"
    case .good: "good"
    case .attention: "attention"
    case nil: "unknown"
    }
  }

  static func escape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for character in text {
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      default: result.append(character)
      }
    }
    return result
  }
}
