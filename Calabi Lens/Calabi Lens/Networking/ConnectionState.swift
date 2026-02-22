import Foundation

enum ConnectionState {
    case connecting
    case connected
    case disconnected(Error?)
}
