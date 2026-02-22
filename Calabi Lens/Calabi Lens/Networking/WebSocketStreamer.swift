import Foundation

final class WebSocketStreamer: NSObject, URLSessionWebSocketDelegate {

    // MARK: - Constants

    private static let maxQueueDepth = 10
    private static let maxReconnectAttempts = 3
    private static let reconnectDelays: [TimeInterval] = [1, 2, 4]

    // MARK: - Callbacks

    var onStateChange: ((ConnectionState) -> Void)?
    var onMetricsUpdate: ((Int, Int) -> Void)?
    var onDropped: (() -> Void)?
    var onRTT: ((Double) -> Void)?

    // MARK: - Private State

    private let sendQueue = DispatchQueue(label: "com.calabiLens.send", qos: .utility)
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var currentURL: URL?

    private var buffer: [Data] = []
    private var isDraining = false
    private var shouldCloseAfterDrain = false
    private var acceptingEnqueues = true

    private var pingTimer: DispatchSourceTimer?

    private var reconnectAttempt = 0
    private var shouldReconnect = false

    // MARK: - Connect

    func connect(to url: URL) {
        sendQueue.async { [weak self] in
            self?._connect(to: url)
        }
    }

    private func _connect(to url: URL) {
        currentURL = url
        reconnectAttempt = 0
        shouldReconnect = false
        notifyStateChange(.connecting)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        startReceiveLoop()
    }

    // MARK: - Disconnect (abort)

    func disconnect() {
        sendQueue.async { [weak self] in
            self?._disconnect()
        }
    }

    private func _disconnect() {
        shouldReconnect = false
        acceptingEnqueues = false
        buffer.removeAll()
        isDraining = false
        shouldCloseAfterDrain = false
        stopPingInternal()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        invalidateSession()
        notifyStateChange(.disconnected(nil))
    }

    // MARK: - Flush and Disconnect

    func flushAndDisconnect() {
        sendQueue.async { [weak self] in
            self?._flushAndDisconnect()
        }
    }

    private func _flushAndDisconnect() {
        shouldReconnect = false
        acceptingEnqueues = false
        stopPingInternal()

        if buffer.isEmpty && !isDraining {
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            invalidateSession()
            notifyStateChange(.disconnected(nil))
        } else {
            shouldCloseAfterDrain = true
            if !isDraining {
                drainNext()
            }
        }
    }

    // MARK: - Enqueue

    func enqueue(_ data: Data) {
        sendQueue.async { [weak self] in
            self?._enqueue(data)
        }
    }

    private func _enqueue(_ data: Data) {
        guard acceptingEnqueues else { return }

        if buffer.count >= Self.maxQueueDepth {
            buffer.removeFirst()
            onDropped?()
        }

        buffer.append(data)

        if !isDraining {
            drainNext()
        }
    }

    // MARK: - Drain Loop

    private func drainNext() {
        dispatchPrecondition(condition: .onQueue(sendQueue))
        isDraining = true

        guard !buffer.isEmpty else {
            isDraining = false
            if shouldCloseAfterDrain {
                shouldCloseAfterDrain = false
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                invalidateSession()
                notifyStateChange(.disconnected(nil))
            }
            return
        }

        let data = buffer.removeFirst()

        task?.send(.data(data)) { [weak self] error in
            guard let self else { return }
            self.sendQueue.async {
                if let error {
                    self.isDraining = false
                    self.handleConnectionError(error)
                    return
                }

                self.onMetricsUpdate?(data.count, self.buffer.count)
                self.drainNext()
            }
        }
    }

    // MARK: - Receive Loop (connection health detection)

    private func startReceiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.startReceiveLoop()
            case .failure(let error):
                self.sendQueue.async {
                    self.handleConnectionError(error)
                }
            }
        }
    }

    // MARK: - Connection Error Handling

    private func handleConnectionError(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(sendQueue))

        guard shouldReconnect else {
            isDraining = false
            task = nil
            invalidateSession()
            notifyStateChange(.disconnected(error))
            return
        }

        isDraining = false
        attemptReconnect(error: error)
    }

    // MARK: - Reconnection

    func enableReconnect() {
        sendQueue.async { [weak self] in
            self?.shouldReconnect = true
            self?.reconnectAttempt = 0
        }
    }

    func disableReconnect() {
        sendQueue.async { [weak self] in
            self?.shouldReconnect = false
        }
    }

    private func attemptReconnect(error: Error) {
        dispatchPrecondition(condition: .onQueue(sendQueue))

        guard reconnectAttempt < Self.maxReconnectAttempts, let url = currentURL else {
            shouldReconnect = false
            isDraining = false
            task = nil
            invalidateSession()
            notifyStateChange(.disconnected(error))
            return
        }

        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1

        notifyStateChange(.connecting)

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        invalidateSession()

        sendQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldReconnect else { return }

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.urlSession = session
            let wsTask = session.webSocketTask(with: url)
            self.task = wsTask
            wsTask.resume()
            self.startReceiveLoop()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.reconnectAttempt = 0
            self.acceptingEnqueues = true
            self.notifyStateChange(.connected)

            if !self.buffer.isEmpty && !self.isDraining {
                self.drainNext()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.isDraining = false
            self.stopPingInternal()

            if self.shouldReconnect, self.reconnectAttempt < Self.maxReconnectAttempts {
                self.task = nil
                self.invalidateSession()
                self.attemptReconnect(error: URLError(.networkConnectionLost))
            } else {
                self.task = nil
                self.invalidateSession()
                self.notifyStateChange(.disconnected(nil))
            }
        }
    }

    // MARK: - Ping / RTT

    func startPing(interval: TimeInterval = 2.0) {
        sendQueue.async { [weak self] in
            self?.startPingInternal(interval: interval)
        }
    }

    func stopPing() {
        sendQueue.async { [weak self] in
            self?.stopPingInternal()
        }
    }

    private func startPingInternal(interval: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(sendQueue))
        stopPingInternal()

        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingInternal() {
        dispatchPrecondition(condition: .onQueue(sendQueue))
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() {
        let start = Date()
        task?.sendPing { [weak self] error in
            guard error == nil else { return }
            let ms = Date().timeIntervalSince(start) * 1000.0
            self?.onRTT?(ms)
        }
    }

    // MARK: - Helpers

    private func notifyStateChange(_ state: ConnectionState) {
        onStateChange?(state)
    }

    private func invalidateSession() {
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
}
