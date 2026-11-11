import Charts
import SwiftUI

private struct WebsiteTrafficRefreshKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var websiteTrafficRefresh: (() -> Void)? {
        get { self[WebsiteTrafficRefreshKey.self] }
        set { self[WebsiteTrafficRefreshKey.self] = newValue }
    }
}

struct WebsiteTrafficView: View {
    @ObservedObject var traffic: WebsiteTrafficStore
    let isDemo: Bool
    @State private var sort: TrafficSort = .sessions
    @State private var ascending = false
    @State private var comparing = true
    @State private var expandedSite: String?

    private enum TrafficSort: String, CaseIterable {
        case website = "Website", users = "Users", sessions = "Sessions", change = "Change", engagement = "Engagement"
    }

    var body: some View {
        GeometryReader { geometry in
            DashboardScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let message = traffic.configurationMessage {
                        ContentUnavailableView("Website traffic", systemImage: "chart.xyaxis.line", description: Text(message))
                            .frame(height: 300)
                    } else {
                        summary
                        dailyChart
                        websiteTable
                    }
                }
                .padding(24)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
        }
        .foregroundStyle(Theme.primary)
        .background(Theme.background)
        .task(id: traffic.period) {
            expandedSite = nil
            await traffic.refresh(demo: isDemo)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await traffic.refresh(demo: isDemo)
            }
        }
        .accessibilityIdentifier("website-traffic-overview")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text("Website traffic").font(.system(size: 22, weight: .semibold))
                    if isDemo {
                        Text("Sample data").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().stroke(Theme.border))
                    }
                }
                Text(traffic.dateCaption).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .help("Complete calendar days in each GA4 property's time zone. Recent dates can still be revised by GA4.")
            }
            Spacer(minLength: 16)
            Picker("Traffic period", selection: $traffic.period) {
                ForEach(WebsiteTrafficPeriod.allCases) { period in Text(period.title).tag(period) }
            }
            .labelsHidden().frame(width: 145)
            .accessibilityIdentifier("website-traffic-period")
            Menu {
                Toggle("Compare with previous \(traffic.period.rawValue) days", isOn: $comparing)
            } label: {
                Text(comparing ? "vs previous \(traffic.period.rawValue) days" : "No comparison")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            statistic("Sessions", value: traffic.hasReports ? traffic.totals.sessions.formatted() : "—",
                      change: WebsiteTrafficTotals.change(traffic.totals.sessions, from: traffic.previousTotals.sessions))
            Divider().padding(.vertical, 16)
            statistic("Pageviews", value: traffic.hasReports ? traffic.totals.pageviews.formatted() : "—",
                      change: WebsiteTrafficTotals.change(traffic.totals.pageviews, from: traffic.previousTotals.pageviews))
            Divider().padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 10) {
                Text("Engagement").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(traffic.totals.engagement.map(percent) ?? "—").font(.system(size: 23, weight: .semibold))
                    if comparing, let current = traffic.totals.engagement, let old = traffic.previousTotals.engagement {
                        let delta = (current - old) * 100
                        Text(String(format: "%+.1f pp", delta)).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(delta >= 0 ? Theme.green : Theme.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
            .help("Engaged sessions divided by sessions across reporting sites. User counts remain distinct per site.")
            Divider().padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 10) {
                Text("Coverage").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                HStack(spacing: 7) {
                    Circle().fill(traffic.reportingSites.count == traffic.sites.count && !traffic.sites.isEmpty ? Theme.green : Theme.amber)
                        .frame(width: 7, height: 7)
                    Text("\(traffic.reportingSites.count) / \(traffic.sites.count) reporting")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
            .help("Fresh reports out of configured website bindings, including sites with zero recorded traffic. Stale reports are excluded from portfolio totals and charts. Unconfigured sites are outside this inventory.")
        }
        .frame(height: 96).background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private func statistic(_ title: String, value: String, change: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 23, weight: .semibold)).monospacedDigit()
                if comparing { changeLabel(change) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Daily sessions").font(.system(size: 14, weight: .semibold))
                Spacer()
                legend("This period", color: Theme.blue)
                if comparing { legend("Previous period", color: Theme.secondary, dashed: true) }
            }
            if traffic.hasReports {
                Chart {
                    ForEach(Array(traffic.daily(previous: false).enumerated()), id: \.offset) { day, sessions in
                        LineMark(x: .value("Day", day), y: .value("Sessions", sessions), series: .value("Period", "Current"))
                            .foregroundStyle(Theme.blue).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if comparing {
                        ForEach(Array(traffic.daily(previous: true).enumerated()), id: \.offset) { day, sessions in
                            LineMark(x: .value("Day", day), y: .value("Sessions", sessions), series: .value("Period", "Previous"))
                                .foregroundStyle(Theme.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: [0, traffic.period.rawValue / 3, traffic.period.rawValue * 2 / 3, traffic.period.rawValue - 1]) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel(anchor: .top) {
                            if let index = value.as(Int.self), let report = traffic.reportingSites.first.flatMap({ traffic.report(for: $0) }),
                               report.days.indices.contains(index) {
                                Text(WebsiteTrafficStore.dateLabel(report.days[index].id)).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.7))
                        AxisValueLabel(anchor: .trailing).foregroundStyle(Theme.secondary)
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 170)
                .accessibilityLabel("Daily sessions across reporting websites")
            } else {
                Text(traffic.isRefreshing ? "Loading traffic…" : "No fresh reports available")
                    .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).frame(height: 170)
            }
        }
        .padding(18).background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private func legend(_ label: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: 20, y: 0)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 4] : []))
                .frame(width: 20, height: 1)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private var sortedSites: [WebsiteTrafficSite] {
        traffic.sites.sorted { left, right in
            let a = traffic.report(for: left), b = traffic.report(for: right)
            if (a == nil) != (b == nil) { return a != nil }
            if sort == .website { return ascending ? left.hostname < right.hostname : left.hostname > right.hostname }
            func value(_ report: WebsiteTrafficReport?) -> Double? {
                guard let report else { return nil }
                switch sort {
                case .website: return nil
                case .users: return Double(report.current.users)
                case .sessions: return Double(report.current.sessions)
                case .change: return report.sessionChange
                case .engagement: return report.current.engagement
                }
            }
            let av = value(a), bv = value(b)
            if (av == nil) != (bv == nil) { return av != nil }
            if av == bv { return left.hostname < right.hostname }
            return ascending ? (av ?? 0) < (bv ?? 0) : (av ?? 0) > (bv ?? 0)
        }
    }

    private var websiteTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                columnHeader(.website).frame(maxWidth: .infinity, alignment: .leading)
                columnHeader(.users).frame(width: 70, alignment: .trailing)
                columnHeader(.sessions).frame(width: 85, alignment: .trailing)
                if comparing { columnHeader(.change).frame(width: 75, alignment: .trailing) }
                Text("\(traffic.period.rawValue)-day trend").foregroundStyle(Theme.secondary).frame(width: 140, alignment: .leading)
                columnHeader(.engagement).frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 12)).padding(.horizontal, 16).frame(height: 36)
            ForEach(sortedSites) { site in
                Divider().overlay(Theme.border)
                siteRow(site)
                if expandedSite == site.id, let query = site.query {
                    WebsiteTrafficBreakdown(query: query, period: traffic.period, demo: isDemo)
                        .id(site.id + String(traffic.period.rawValue))
                }
            }
            Divider().overlay(Theme.border)
            HStack {
                if traffic.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Updating traffic…")
                } else if let updated = traffic.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago · Hourly refresh")
                } else if !traffic.sites.isEmpty {
                    Text("Traffic unavailable · Retry or renew reader access")
                }
                Spacer()
            }
            .font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).frame(height: 36)
        }
        .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private func columnHeader(_ column: TrafficSort) -> some View {
        Button {
            if sort == column { ascending.toggle() } else { sort = column; ascending = column == .website }
        } label: {
            HStack(spacing: 3) {
                Text(column.rawValue)
                if sort == column { Image(systemName: ascending ? "arrow.up" : "arrow.down").font(.system(size: 10)) }
            }
            .foregroundStyle(sort == column ? Theme.primary : Theme.secondary)
        }
        .buttonStyle(.plain).help("Sort by \(column.rawValue.lowercased())")
    }

    private func siteRow(_ site: WebsiteTrafficSite) -> some View {
        let report = traffic.report(for: site)
        let stale = traffic.isStale(site)
        return Button {
            expandedSite = expandedSite == site.id ? nil : site.id
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(site.hostname).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if stale || (report == nil && !traffic.isRefreshing) {
                        Text(stale ? "Stale · refresh unavailable" : (site.query == nil ? "Website binding needs review" : "Traffic unavailable"))
                            .font(.system(size: 10)).foregroundStyle(Theme.amber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(report.map { $0.current.users.formatted() } ?? "—").frame(width: 70, alignment: .trailing)
                    .help("Distinct active users over the full period for this hostname. Users can overlap across websites.")
                Text(report.map { $0.current.sessions.formatted() } ?? "—").frame(width: 85, alignment: .trailing)
                if comparing {
                    changeLabel(report?.sessionChange, new: report.map { $0.previous.sessions == 0 && $0.current.sessions > 0 } ?? false)
                        .frame(width: 75, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    TrafficSparkline(values: report?.days.map(\.sessions) ?? [],
                                     color: (report?.sessionChange ?? 0) < 0 ? Theme.red : Theme.blue)
                        .frame(height: 22)
                    if report?.current.sessions == 0 {
                        Text("No recorded traffic").font(.system(size: 9)).foregroundStyle(Theme.subtle)
                    }
                }
                .frame(width: 140)
                Text(report?.current.engagement.map(percent) ?? "—").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(stale ? Theme.secondary : Theme.primary)
            .padding(.horizontal, 16).frame(height: 48)
            .background(expandedSite == site.id ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(site.hostname), \(report.map { "\($0.current.sessions) sessions" } ?? "traffic unavailable")\(stale ? ", stale" : "")")
        .help("Show traffic sources and landing pages. \(site.repository)")
    }

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private func changeLabel(_ value: Double?, new: Bool = false) -> some View {
        Text(value.map { String(format: "%+.1f%%", $0 * 100) } ?? (new ? "New" : "—"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(value.map { $0 < 0 ? Theme.red : Theme.green } ?? Theme.secondary)
    }
}

private struct TrafficSparkline: View {
    let values: [Int]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            if !values.isEmpty {
                let maximum = max(values.max() ?? 0, 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: geometry.size.width * Double(index) / Double(max(values.count - 1, 1)),
                                            y: geometry.size.height - 2 - (geometry.size.height - 4) * Double(value) / Double(maximum))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WebsiteTrafficBreakdown: View {
    let query: WebsiteTrafficQuery
    let period: WebsiteTrafficPeriod
    let demo: Bool
    @State private var sources: [(String, Int)] = []
    @State private var pages: [(String, Int)] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            breakdown("Traffic sources", rows: sources)
            breakdown("Landing pages", rows: pages)
        }
        .padding(18).background(Theme.background.opacity(0.5))
        .task {
            if demo {
                sources = [("Organic Search", 4210), ("Direct", 3180), ("Referral", 1820)]
                pages = [("/", 6180), ("/library", 2410), ("/about", 840)]
            } else {
                let result = await Task.detached(priority: .utility) {
                    Result { (try query.breakdown(period: period, dimension: "sessionDefaultChannelGroup"),
                              try query.breakdown(period: period, dimension: "landingPagePlusQueryString")) }
                }.value
                switch result {
                case .success(let values): sources = values.0; pages = values.1
                case .failure: failed = true
                }
            }
            loading = false
        }
    }

    private func breakdown(_ title: String, rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Sessions").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            if loading || failed || rows.isEmpty {
                Text(loading ? "Loading…" : (failed ? "Breakdown unavailable" : "No recorded traffic"))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            } else {
                ForEach(rows.indices, id: \.self) { index in
                    HStack {
                        Text(rows[index].0).lineLimit(1).truncationMode(.middle).help(rows[index].0)
                        Spacer()
                        Text(rows[index].1.formatted()).monospacedDigit()
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
