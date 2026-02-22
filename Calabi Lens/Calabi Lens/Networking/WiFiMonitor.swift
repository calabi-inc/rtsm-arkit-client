import Foundation
import Network

final class WiFiMonitor: ObservableObject {

    @Published private(set) var isWiFiConnected = false
    @Published private(set) var localIP: String?

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "com.calabiLens.wifi")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let ip = connected ? Self.getWiFiAddress() : nil
            DispatchQueue.main.async {
                self?.isWiFiConnected = connected
                self?.localIP = ip
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    static func getWiFiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil, 0,
                NI_NUMERICHOST
            )
            return String(cString: hostname)
        }
        return nil
    }
}
