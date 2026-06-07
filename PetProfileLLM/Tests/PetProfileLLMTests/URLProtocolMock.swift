// URLProtocolMock.swift
// 测试 helper — 用 URLProtocol 子类拦截 URLSession 请求，返回 canned response
//
// 关键 API：
//   - URLProtocolMock.register()  → 注册 mock；之后所有用 mockSession 的 URLSession.dataTask
//                                    都会被这个 URLProtocol 处理
//   - URLProtocolMock.unregister() → 注销
//   - URLProtocolMock.setResponse(...) → 设置下次的 canned response
//   - URLProtocolMock.setSequence(...) → 设置多个 response 顺序返回（给 retry 测试用）
//   - URLProtocolMock.capturedRequests → 累计捕获的 URLRequest（验证 header / body）
//
// 用法：
//   ```swift
//   let mock = URLProtocolMock()
//   mock.register()
//   defer { mock.unregister() }
//   mock.setResponse(statusCode: 200, json: ["choices": [...]])
//   let session = URLSession(configuration: .ephemeral, protocolClasses: [MockHTTPURLProtocol.self])
//   // MockHTTPURLProtocol 内部会从 URLProtocolMock 查 response
//   ```
//
// 不做：
//   - 不模拟 TLS / 证书
//   - 不模拟 chunked streaming
//

import Foundation

// MARK: - URLProtocolMock 单例

public final class URLProtocolMock: @unchecked Sendable {

    public struct MockResponse {
        public var statusCode: Int
        public var headers: [String: String]
        public var body: Data

        public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }

        public static func json(_ obj: [String: Any], statusCode: Int = 200, extraHeaders: [String: String] = [:]) -> MockResponse {
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
            var h = extraHeaders
            h["Content-Type"] = h["Content-Type"] ?? "application/json"
            return MockResponse(statusCode: statusCode, headers: h, body: data)
        }
    }

    public static let shared = URLProtocolMock()

    private let lock = NSLock()
    private var sequence: [MockResponse] = []
    private var sequenceIndex: Int = 0
    private var errorSequence: [Error] = []
    private var errorIndex: Int = 0
    private var delay: TimeInterval = 0
    private var generation: Int = 0

    public private(set) var capturedRequests: [URLRequest] = []

    private init() {}

    // MARK: - 公共 API

    /// 注册 mock（让 URLSession 走我们）
    public func register() {
        URLProtocol.registerClass(MockHTTPURLProtocol.self)
    }

    /// 注销
    public func unregister() {
        URLProtocol.unregisterClass(MockHTTPURLProtocol.self)
    }

    /// 重置 capturedRequests + sequence + error（递增 generation 让 in-flight 的 delay abort）
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        sequence.removeAll()
        sequenceIndex = 0
        errorSequence.removeAll()
        errorIndex = 0
        delay = 0
        capturedRequests.removeAll()
    }

    /// 设置下一次返回的 response（单次）
    public func setResponse(_ r: MockResponse) {
        lock.lock(); defer { lock.unlock() }
        sequence = [r]
        sequenceIndex = 0
    }

    /// 设置多次 response 的顺序（retry 测试：第一次失败 → 第二次成功）
    public func setSequence(_ rs: [MockResponse]) {
        lock.lock(); defer { lock.unlock() }
        sequence = rs
        sequenceIndex = 0
    }

    /// 设置一个 error queue（每次 request 消费一个 error；耗尽后走 sequence 或 500）
    public func setErrorSequence(_ errs: [Error]) {
        lock.lock(); defer { lock.unlock() }
        errorSequence = errs
        errorIndex = 0
    }

    /// 便捷：setErrorSequence([err]) — 单 error 队列
    public func setError(_ err: Error) {
        setErrorSequence([err])
    }

    /// 模拟网络延迟（默认 0 = 立即返回）
    public func setDelay(_ s: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        delay = s
    }

    /// 构造一个走 mock 的 URLSession
    public func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 内部访问

    fileprivate func nextResponse() -> MockResponse? {
        lock.lock(); defer { lock.unlock() }
        guard sequenceIndex < sequence.count else { return nil }
        let r = sequence[sequenceIndex]
        sequenceIndex += 1
        return r
    }

    fileprivate func nextError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        guard errorIndex < errorSequence.count else { return nil }
        let e = errorSequence[errorIndex]
        errorIndex += 1
        return e
    }

    fileprivate func currentDelay() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return delay
    }

    fileprivate func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// 让调用方在 sleep 时也能感知 generation 变化（reset 一发生立即返回）
    fileprivate func sleepOrAbort(deadline: Date, generation: Int) {
        while Date() < deadline {
            if currentGeneration() != generation { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    fileprivate func record(request: URLRequest, startGen: Int) {
        lock.lock(); defer { lock.unlock() }
        // generation 已变 → 已被 reset，不应污染新 test 的 capturedRequests
        guard generation == startGen else { return }
        // URLSession 在传 URLRequest 给 URLProtocol 时，httpBody 可能已被消化、
        // 转成 httpBodyStream（NSCachedURLRequest 会把 body 移到 stream）。
        // 这里把 body 显式读出来存一份，方便测试断言 body 形状。
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            captured.httpBody = data
        }
        capturedRequests.append(captured)
    }
}

// MARK: - URLProtocol 子类

final class MockHTTPURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let mock = URLProtocolMock.shared
        let startGen = mock.currentGeneration()
        mock.record(request: self.request, startGen: startGen)

        // 延迟（给 timeout / 慢响应测试用）。如果期间 generation 变了（reset），
        // 立即 abort — 避免老 test 的 sleep 影响新 test 的 response。
        let delay = mock.currentDelay()
        if delay > 0 {
            let deadline = Date().addingTimeInterval(delay)
            mock.sleepOrAbort(deadline: deadline, generation: startGen)
        }

        // generation 已变 → 老请求已被 reset，新 test 会另起一个 URLProtocol 实例；
        // 老实例直接 abort（不返回 response，避免污染新 test 的 capturedRequests）
        if mock.currentGeneration() != startGen {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockHTTPURLProtocol", code: -999, userInfo: [NSLocalizedDescriptionKey: "aborted by reset"]))
            return
        }

        // error 优先（从 error queue 消费）
        if let err = mock.nextError() {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }

        // 顺序 response
        guard let r = mock.nextResponse() else {
            // 没有设置 → 返回 500
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"no mock configured\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: r.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: r.headers
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // 不做 cleanup
    }
}
