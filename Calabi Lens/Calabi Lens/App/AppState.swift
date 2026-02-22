import Foundation

enum AppState: Equatable {
    case idle
    case connecting
    case connected
    case recording(sessionID: UUID)
    case reconnecting(attempt: Int, sessionID: UUID)
    case permissionError
    case failed(Error?)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.connecting, .connecting),
             (.connected, .connected),
             (.permissionError, .permissionError):
            return true
        case (.recording(let a), .recording(let b)):
            return a == b
        case (.reconnecting(let a1, let a2), .reconnecting(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.failed(let a), .failed(let b)):
            return a?.localizedDescription == b?.localizedDescription
        default:
            return false
        }
    }

    var isRecording: Bool {
        switch self {
        case .recording, .reconnecting: return true
        default: return false
        }
    }

    var isConnected: Bool {
        switch self {
        case .connected, .recording, .reconnecting: return true
        default: return false
        }
    }

    var sessionID: UUID? {
        switch self {
        case .recording(let id): return id
        case .reconnecting(_, let id): return id
        default: return nil
        }
    }
}
