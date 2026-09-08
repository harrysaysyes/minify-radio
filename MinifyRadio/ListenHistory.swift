import Foundation

struct ListenEntry: Codable, Identifiable, Equatable {
    let id:      UUID
    let date:    Date
    let station: String
    let title:   String
}

/// The listen history: every identified track title, newest last.
/// Pure value type — persistence is the engine's job.
struct ListenHistory: Codable, Equatable {

    static let capacity = 200

    private(set) var entries: [ListenEntry] = []

    mutating func log(title rawTitle: String, station: String, date: Date = Date()) {
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        // ICY streams repeat the current title on reconnects — skip consecutive dupes
        if let last = entries.last, last.title == title, last.station == station { return }
        entries.append(ListenEntry(id: UUID(), date: date, station: station, title: title))
        if entries.count > ListenHistory.capacity {
            entries.removeFirst(entries.count - ListenHistory.capacity)
        }
    }
}
