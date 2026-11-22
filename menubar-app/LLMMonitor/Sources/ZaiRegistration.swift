import Foundation

/// Pool provenance stays on the credential that owns the key. Existing Z.ai
/// credentials and explicit local registrations have source "zai-key".
enum ZaiRegistration {
    static let poolSource = "zai-pool"
    static let disabledSource = "zai-pool-disabled"

    static func isPool(_ source: String?) -> Bool {
        source == poolSource || source == disabledSource
    }

    /// This predicate is used before loading rows into the UI, ranking, or an
    /// export. A database predating credential sources contains only local rows.
    static func visibleAccounts(in db: Connection, exporting: Bool = false, account: String = "accounts.id") -> String {
        guard tableColumns(db, "oauth_credentials").contains("source") else { return "1" }
        let sources = exporting ? "'zai-pool', 'zai-pool-disabled'" : "'zai-pool-disabled'"
        return "NOT EXISTS (SELECT 1 FROM oauth_credentials z WHERE z.account_id = \(account) AND z.source IN (\(sources)))"
    }

    enum RegistrationError: Error, LocalizedError {
        case conflict, storage
        var errorDescription: String? {
            switch self {
            case .conflict: return "Conflicting Z.ai identities. The existing registrations were preserved."
            case .storage: return "Could not store the Z.ai registration."
            }
        }
    }

    struct Existing {
        let id: String
        let email: String?
        let keyMatches: Bool
        let source: String?
        let active: Bool
        let label: String?
    }

    /// Keep the same row (and its history) when a label-only seat gains an
    /// email or its key rotates. Ambiguous evidence never authorizes a merge.
    static func existing(_ seat: ZaiDiscovery.Seat, db: Connection) throws -> Existing? {
        let file = seat.file
        let rows = try db.prepare("""
            SELECT a.id, a.email, c.access_token = ?, c.source, c.is_active, c.label
              FROM accounts a LEFT JOIN oauth_credentials c ON c.account_id = a.id
             WHERE a.provider = 'zai' AND (
                   a.id = ? OR lower(a.email) = lower(?) OR c.access_token = ?
                   OR (c.source IN ('zai-pool', 'zai-pool-disabled') AND c.label = ?))
            """).bind(file.apiKey, file.accountId, file.email, file.apiKey, file.label)
        var match: Existing?
        for row in rows {
            guard match == nil, let id = row[0] as? String else { throw RegistrationError.conflict }
            let email = row[1] as? String
            let keyMatches = (row[2] as? Int64) == 1
            let source = row[3] as? String
            if let email, let incoming = file.email, email.caseInsensitiveCompare(incoming) != .orderedSame {
                throw RegistrationError.conflict
            }
            if seat.fromPool && !isPool(source) && !keyMatches { throw RegistrationError.conflict }
            match = Existing(id: id, email: email, keyMatches: keyMatches, source: source, active: (row[4] as? Int64) == 1, label: row[5] as? String)
        }
        return match
    }

    /// Hide absent, disabled, and superseded pool credentials before polling.
    /// Drop the pool key while retaining the label and historical readings.
    static func deactivateMissing(_ seats: [ZaiDiscovery.Seat], db: Connection) throws {
        let enabled = Dictionary(uniqueKeysWithValues: seats.filter(\.fromPool).map { ($0.file.label, $0.file.apiKey) })
        let rows = try db.prepare("SELECT id, access_token, label FROM oauth_credentials WHERE source = 'zai-pool'")
        let inactive = rows.compactMap { row -> (Int64, String?)? in
            guard let id = row[0] as? Int64 else { return nil }
            guard let key = row[1] as? String, let label = row[2] as? String, enabled[label] == key else {
                return (id, row[1] as? String)
            }
            return nil
        }
        for (id, previousKey) in inactive {
            try db.run("""
                UPDATE oauth_credentials SET source = ?, is_active = 0, access_token = NULL
                WHERE id = ? AND source = ? AND access_token IS ?
                """, disabledSource, id, poolSource, previousKey)
        }
    }
}
