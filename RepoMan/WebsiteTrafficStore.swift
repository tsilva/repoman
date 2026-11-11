import Combine
import Foundation

@MainActor
final class WebsiteTrafficStore: ObservableObject {
    @Published var period: WebsiteTrafficPeriod = .month
    @Published private(set) var sites: [WebsiteTrafficSite] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var configurationMessage: String?
    @Published private var cache: [CacheKey: Entry] = [:]
    private struct CacheKey: Hashable { let query: WebsiteTrafficQuery; let period: WebsiteTrafficPeriod }
    private struct Entry {
        let report: WebsiteTrafficReport?
        let failed: Bool
        let retryAt: Date
    }
    private var configured = false
    private var nextConfigurationRead = Date.distantPast
    private let configurationURL: URL

    init(configurationURL: URL? = nil) {
        self.configurationURL = configurationURL ?? RepositoryStore.analyticsConfigurationURL
    }

    func report(for site: WebsiteTrafficSite) -> WebsiteTrafficReport? {
        guard let query = site.query else { return nil }
        return cache[CacheKey(query: query, period: period)]?.report
    }

    func isStale(_ site: WebsiteTrafficSite) -> Bool {
        guard let query = site.query, let entry = cache[CacheKey(query: query, period: period)],
              let report = entry.report else { return false }
        return entry.failed || Date().timeIntervalSince(report.fetchedAt) >= 3600
    }

    var reportingSites: [WebsiteTrafficSite] { sites.filter { report(for: $0) != nil && !isStale($0) } }
    var hasReports: Bool { !reportingSites.isEmpty }
    var lastUpdated: Date? { reportingSites.compactMap { report(for: $0)?.fetchedAt }.min() }

    var totals: WebsiteTrafficTotals { sum(previous: false) }
    var previousTotals: WebsiteTrafficTotals { sum(previous: true) }
    private func sum(previous: Bool) -> WebsiteTrafficTotals {
        let reports = reportingSites.compactMap { report(for: $0) }.map { previous ? $0.previous : $0.current }
        return WebsiteTrafficTotals(users: 0, sessions: reports.reduce(0) { $0 + $1.sessions },
                                   pageviews: reports.reduce(0) { $0 + $1.pageviews },
                                   engagedSessions: reports.reduce(0) { $0 + $1.engagedSessions })
    }

    func daily(previous: Bool) -> [Int] {
        let reports = reportingSites.compactMap { report(for: $0) }
        return (0..<period.rawValue).map { index in
            reports.reduce(0) { value, report in
                let days = previous ? report.previousDays : report.days
                return value + (days.indices.contains(index) ? days[index].sessions : 0)
            }
        }
    }

    var dateCaption: String {
        guard let report = reportingSites.compactMap({ report(for: $0) }).first,
              let first = report.days.first, let last = report.days.last else { return period.title }
        return "\(Self.dateLabel(first.id)) – \(Self.dateLabel(last.id))"
    }

    static func dateLabel(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyyMMdd"
        guard let date = parser.date(from: key) else { return key }
        parser.dateFormat = "d MMM"
        return parser.string(from: date)
    }

    func refresh(demo: Bool, force: Bool = false) async {
        guard !isRefreshing else { return }
        if demo {
            loadDemo()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let selectedPeriod = period
        if force || !configured || Date() >= nextConfigurationRead {
            let configurationURL = self.configurationURL
            let result = await Task.detached(priority: .utility) {
                Result { try GA4TrafficConfiguration.load(from: configurationURL) }
            }.value
            switch result {
            case .success(let configuration):
                sites = configuration.map(WebsiteTrafficSite.sites(in:)) ?? []
                configurationMessage = configuration == nil
                    ? "Configure the approved GA4 reader and production hostnames in analytics.json to show website traffic."
                    : (sites.isEmpty ? "No website bindings are configured in analytics.json." : nil)
                let queries = Set(sites.compactMap(\.query))
                cache = cache.filter { queries.contains($0.key.query) }
            case .failure:
                sites = []
                cache = [:]
                configurationMessage = "The analytics configuration could not be read. Check the local analytics.json file."
            }
            configured = true
            nextConfigurationRead = Date().addingTimeInterval(60)
        }
        let now = Date()
        let due = sites.compactMap(\.query).filter {
            force || (cache[CacheKey(query: $0, period: selectedPeriod)]?.retryAt ?? .distantPast) <= now
        }
        await withTaskGroup(of: (WebsiteTrafficQuery, WebsiteTrafficReport?).self) { group in
            var pending = due.makeIterator()
            for _ in 0..<4 {
                guard let query = pending.next() else { break }
                group.addTask(priority: .utility) { (query, try? query.load(period: selectedPeriod)) }
            }
            for await (query, report) in group {
                guard !Task.isCancelled, period == selectedPeriod else { group.cancelAll(); continue }
                let key = CacheKey(query: query, period: selectedPeriod)
                cache[key] = Entry(report: report ?? cache[key]?.report, failed: report == nil,
                                   retryAt: Date().addingTimeInterval(report == nil ? 300 : 3600))
                if let next = pending.next() {
                    group.addTask(priority: .utility) { (next, try? next.load(period: selectedPeriod)) }
                }
            }
        }
    }

    private func loadDemo() {
        let names = ["scummweb", "modelarchviz", "waxon", "embeddingviz", "apipit", "cv", "moviegen", "reshoot"]
        let sessions = [12560, 5410, 4120, 2360, 1720, 1180, 0, 0]
        let previous = [10064, 4612, 3794, 2516, 1534, 897, 0, 0]
        let users = [6842, 3126, 2087, 1412, 986, 804, 0, 0]
        let engagement = [0.682, 0.618, 0.741, 0.593, 0.546, 0.482, 0, 0]
        sites = names.map {
            WebsiteTrafficSite(repository: "example/\($0)", hostname: "\($0).tsilva.eu",
                               query: WebsiteTrafficQuery(reader: "/demo", propertyId: "1", hostname: "\($0).tsilva.eu"))
        }
        let zone = TimeZone(identifier: "Europe/Lisbon")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "yyyyMMdd"
        for (index, site) in sites.enumerated() {
            guard index != 7, let query = site.query else { continue }
            func days(total: Int, offset: Int) -> [WebsiteTrafficDay] {
                let weights = (0..<period.rawValue).map { day in
                    1 + sin(Double(day) * 0.32 + Double(index) * 0.7) * 0.25
                        + cos(Double(day) * 0.87 + Double(index)) * 0.1
                        + ([9, 22].contains(day) ? 0.65 : 0)
                }
                let weightTotal = weights.reduce(0, +)
                var values = weights.map { Int(Double(total) * $0 / weightTotal) }
                values[values.count - 1] += total - values.reduce(0, +)
                return (0..<period.rawValue).map { day in
                    let date = calendar.date(byAdding: .day, value: day - period.rawValue - offset, to: Date())!
                    return WebsiteTrafficDay(id: formatter.string(from: date), sessions: values[day])
                }
            }
            let current = WebsiteTrafficTotals(users: users[index], sessions: sessions[index],
                                              pageviews: sessions[index] * 2, engagedSessions: Int(Double(sessions[index]) * engagement[index]))
            let old = WebsiteTrafficTotals(users: users[index] / 2, sessions: previous[index],
                                          pageviews: previous[index] * 2, engagedSessions: Int(Double(previous[index]) * 0.6))
            cache[CacheKey(query: query, period: period)] = Entry(
                report: WebsiteTrafficReport(current: current, previous: old, days: days(total: sessions[index], offset: 0),
                                             previousDays: days(total: previous[index], offset: period.rawValue),
                                             timeZone: zone.identifier, fetchedAt: Date()), failed: false,
                retryAt: .distantFuture)
        }
    }
}
