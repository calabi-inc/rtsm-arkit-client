import Foundation

enum ConnectionState {
    case connecting
    case handshaking
    case connected
    case disconnected(Error?)
}
