import Foundation
import GRDB

/// A saved number names one work on each website: two websites that number their works
/// differently can hold two different works under one number, and both can be saved.
/// A work whose website is unknown (older saves, other apps' backups) waits for one: the first
/// save of that number from a website claims it.
enum WorkIdentity {
    /// Websites that number their works the same way as the given one. Tests replace it.
    nonisolated(unsafe) static var siblings: (String) -> [String] = { ComicSites.siblings(of: $0) }

    static func rows(_ db: Database, galleryId: Int64) throws -> [Work] {
        try Work.filter(Work.Columns.galleryId == galleryId).order(Work.Columns.id).fetchAll(db)
    }

    /// The saved work a number opened on `site` refers to: the one saved from that website,
    /// then from one that numbers its works the same way, then one whose website is unknown.
    /// Without a website, the one whose website is unknown, else the first saved.
    static func pick(_ rows: [Work], site: String?) -> Work? {
        guard let site, !site.isEmpty else { return rows.first { $0.site == nil } ?? rows.first }
        if let exact = rows.first(where: { $0.site == site }) { return exact }
        let family = Set(siblings(site))
        if !family.isEmpty, let sibling = rows.first(where: { $0.site.map(family.contains) ?? false }) { return sibling }
        return rows.first { $0.site == nil }
    }

    /// Where a work from a file that does not say its website lands: the saved one whose
    /// website is unknown, else a saved one that is the same work. When the file says nothing
    /// about the work either, there is no telling, so it stays with the first saved one.
    static func importMatch(_ rows: [Work], title: String?, artists: String?) -> Work? {
        if let unknown = rows.first(where: { $0.site == nil }) { return unknown }
        guard !rows.isEmpty else { return nil }
        let described = !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty || !(artists ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard described else { return rows.first }
        return rows.first { sameWork($0, title: title, artists: artists) }
    }

    /// Shared artists decide; without artists on both sides, the cleaned titles do. With
    /// neither, the two cannot be told apart and count as the same.
    static func sameWork(_ work: Work, title: String?, artists: String?) -> Bool {
        let saved = names(work.artists), incoming = names(artists)
        if !saved.isEmpty && !incoming.isEmpty { return !saved.isDisjoint(with: incoming) }
        let first = WorkMatcher.normalizedTitle(work.title ?? ""), second = WorkMatcher.normalizedTitle(title ?? "")
        if !first.isEmpty && !second.isEmpty { return first == second }
        return true
    }

    static func names(_ list: String?) -> Set<String> { WorkMatcher.names((list ?? "").split(separator: ",").map(String.init)) }

    /// One row per number travels as that number, as older versions expect: the first website
    /// by name, so every device picks the same one, and only without any the one whose website
    /// is unknown. A number row without a website then means its sender knows no website for it.
    static let primaryCondition = "w.id = (SELECT p.id FROM works p WHERE p.gallery_id = w.gallery_id ORDER BY p.site IS NULL, p.site LIMIT 1)"

    /// The row a number alone names, as older versions send it.
    static func primary(_ rows: [Work]) -> Work? {
        rows.filter { $0.site != nil }.min { $0.site! < $1.site! } ?? rows.first { $0.site == nil }
    }

    /// Covers of works saved from a website carry it in their file name, so two works under
    /// one number never share a cover file.
    static func thumbnailName(galleryId: Int64, site: String?) -> String {
        guard let site, !site.isEmpty else { return "native_\(galleryId).jpg" }
        let slug = String(site.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return "native_\(galleryId)_\(slug).jpg"
    }
}

/// Which numbers count as saved on each website: the works saved from it or from one that
/// numbers its works the same way, and those whose website is unknown.
struct SavedWorkKeys: Equatable, Sendable {
    var unknown = Set<Int64>()
    var bySite: [String: Set<Int64>] = [:]

    static func fetch(_ db: Database) throws -> SavedWorkKeys {
        var keys = SavedWorkKeys()
        for row in try Row.fetchAll(db, sql: "SELECT gallery_id, site FROM works") {
            let id: Int64 = row["gallery_id"]
            if let site: String = row["site"], !site.isEmpty { keys.bySite[site, default: []].insert(id) } else { keys.unknown.insert(id) }
        }
        return keys
    }

    func ids(on site: String) -> Set<Int64> {
        var result = unknown.union(bySite[site] ?? [])
        for sibling in WorkIdentity.siblings(site) { result.formUnion(bySite[sibling] ?? []) }
        return result
    }
}

/// Recognizes one work listed by two websites. Their listings copy each other's text, so
/// a cleaned title, the artists and the page count are enough to tell.
enum WorkMatcher {
    /// Lowercased, width-folded, without bracketed parts such as circles, events, languages
    /// and translators, and without spaces or punctuation.
    static func normalizedTitle(_ title: String) -> String {
        let folded = title.precomposedStringWithCompatibilityMapping.lowercased()
        var depth = 0, kept = ""
        for character in folded {
            if "[({【（〔".contains(character) { depth += 1; continue }
            if "])}】）〕".contains(character) { depth = max(0, depth - 1); continue }
            if depth == 0 { kept.append(character) }
        }
        let clean = { (text: String) in String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
        let result = clean(kept)
        return result.isEmpty ? clean(folded) : result
    }

    static func names(_ values: [String]) -> Set<String> {
        Set(values.map { $0.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    struct Fingerprint: Sendable {
        let titles: Set<String>
        let artists: Set<String>
        let pages: Int
    }

    static func fingerprint(titles: [String], artists: [String], pages: Int) -> Fingerprint {
        Fingerprint(titles: Set(titles.map(normalizedTitle).filter { $0.count >= 2 }), artists: names(artists), pages: pages)
    }

    /// Same cleaned title, page counts at most two apart (credit pages), and shared artists
    /// when both name some.
    static func isSameWork(_ first: Fingerprint, _ second: Fingerprint) -> Bool {
        guard !first.titles.isDisjoint(with: second.titles) else { return false }
        if first.pages > 0, second.pages > 0, abs(first.pages - second.pages) > 2 { return false }
        if !first.artists.isEmpty, !second.artists.isEmpty, first.artists.isDisjoint(with: second.artists) { return false }
        return true
    }
}
