import Foundation

struct SlukaCommand: Codable {
    let id: String
    let textRevision: Int
    let surface: String
    let key: String
    let expectedStatus: Int
    let grade: Int?
    let expiresAt: Int64
    var translatesPassage: Bool? = nil
}

struct SlukaCommandTicket: Decodable {
    let id: String
    let textRevision: Int
}

struct SlukaCommandResult: Decodable {
    enum Outcome: String, Decodable {
        case applied, unchanged, lookup, noDefinition, translated, stale, ambiguous, unavailable, conflict, unconfirmed, busy, invalid
    }

    let id: String
    let textRevision: Int
    let outcome: Outcome
    let status: Int?
    let lookup: SlukaObservation.Lookup?
    var translation: String? = nil
}

struct BoundedSlukaCommand {
    let request: SlukaCommand
    let callback: (SlukaCommandResult.Outcome, SlukaCommandResult?) -> Void
    var offered = false
    var committed = false

    var unexpired: Bool {
        Int64(Date().timeIntervalSince1970 * 1_000) < request.expiresAt
    }

    func matches(id: String, textRevision: Int) -> Bool {
        offered && unexpired && request.id == id && request.textRevision == textRevision
    }

    func accepts(_ result: SlukaCommandResult) -> Bool {
        guard matches(id: result.id, textRevision: result.textRevision) else { return false }
        if request.translatesPassage == true {
            guard result.status == nil, result.lookup == nil else { return false }
            switch result.outcome {
            case .translated:
                guard let translation = result.translation else { return false }
                return !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && translation.utf16.count <= 4000
            case .stale, .unavailable, .unconfirmed, .busy, .invalid:
                return result.translation == nil
            default: return false
            }
        }
        guard result.translation == nil else { return false }
        if let status = result.status, !(0...7).contains(status) { return false }
        if let lookup = result.lookup {
            guard lookup.surface == request.surface, lookup.key == request.key, lookup.valid else { return false }
        }
        switch result.outcome {
        case .applied: return committed && request.grade != nil && result.status == request.grade
        case .unchanged: return request.grade != nil && result.status == request.grade
        case .lookup: return request.grade == nil && result.lookup != nil
        case .noDefinition: return request.grade == nil && result.lookup == nil
        case .translated: return false
        default: return true
        }
    }
}
