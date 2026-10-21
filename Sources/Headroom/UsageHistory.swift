import Combine
import Foundation

/// Each limit's percentage over the last 7 days, saved on this Mac only
/// (~/Library/Application Support/Headroom/history.json).
@MainActor
final class UsageHistory: ObservableObject {
    struct Point: Codable, Equatable {
        let t: Date
        let p: Double
    }

    struct Series: Codable, Identifiable, Equatable {
        let service: ServiceID
        let limitId: String
        var title: String
        /// Position among the service's limits, so charts keep the app's order.
        var order: Int
        var points: [Point]

        var id: String { service.rawValue + "|" + limitId }
    }

    static let keep: TimeInterval = 7 * 86_400

    @Published private(set) var series: [String: Series] = [:]

    init() {
        series = Self.load()
        prune()
    }

    func series(for service: ServiceID) -> [Series] {
        series.values.filter { $0.service == service }.sorted { $0.order < $1.order }
    }

    var services: [ServiceID] {
        ServiceID.allCases.filter { service in series.values.contains { $0.service == service && !$0.points.isEmpty } }
    }

    /// Adds a point per limit, skipping near-duplicates so the file stays small.
    func record(_ snapshot: ServiceSnapshot) {
        var changed = false
        for (index, limit) in snapshot.limits.enumerated() {
            guard let percent = limit.percent else { continue }
            let key = snapshot.service.rawValue + "|" + limit.id
            var entry = series[key] ?? Series(service: snapshot.service, limitId: limit.id, title: limit.title,
                                              order: index, points: [])
            entry.title = limit.title
            entry.order = index
            if let last = entry.points.last,
               snapshot.fetchedAt.timeIntervalSince(last.t) < 240,
               abs(last.p - percent) < 1 {
                series[key] = entry
                continue
            }
            entry.points.append(Point(t: snapshot.fetchedAt, p: percent))
            series[key] = entry
            changed = true
        }
        if changed {
            prune()
            save()
        }
    }

    func clear() {
        series = [:]
        save()
    }

    func clear(_ service: ServiceID) {
        series = series.filter { $0.value.service != service }
        save()
    }

    // MARK: Storage

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        for key in series.keys {
            series[key]?.points.removeAll { $0.t < cutoff }
            if series[key]?.points.isEmpty == true { series[key] = nil }
        }
    }

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private static func load() -> [String: Series] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let list = try? decoder.decode([Series].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Array(series.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
