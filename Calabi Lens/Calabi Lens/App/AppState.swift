import Foundation

enum AppState {
    case idle
    case configuring
    case capturing
    case streaming
    case error(String)
}
