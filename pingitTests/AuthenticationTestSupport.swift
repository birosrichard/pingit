import Foundation
import Security

@MainActor
final class MockKeychain {
    var item: [String: Any]?
    var readStatus: OSStatus?
    var addStatus: OSStatus?
    var updateStatus: OSStatus?
    var deleteStatus: OSStatus?
    var reads = 0
    var adds = 0
    var updates = 0
    var deletes = 0
    var lastQuery: [String: Any] = [:]

    var token: String? {
        guard let data = item?[kSecValueData as String] as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var store: KeychainCredentialStore {
        KeychainCredentialStore(service: "dev.biros.pingit.tests", operations: .init(
            read: { query in
                self.reads += 1
                self.lastQuery = query as! [String: Any]
                if let status = self.readStatus { return (status, nil) }
                guard let item = self.item else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item[kSecValueData as String] as CFTypeRef?)
            },
            add: { query in
                self.adds += 1
                if let status = self.addStatus { return status }
                guard self.item == nil else { return errSecDuplicateItem }
                self.item = query as? [String: Any]
                return errSecSuccess
            },
            update: { _, attributes in
                self.updates += 1
                if let status = self.updateStatus { return status }
                self.item?.merge(attributes as! [String: Any]) { _, new in new }
                return errSecSuccess
            },
            delete: { query in
                self.deletes += 1
                self.lastQuery = query as! [String: Any]
                if let status = self.deleteStatus { return status }
                guard self.item != nil else { return errSecItemNotFound }
                self.item = nil
                return errSecSuccess
            }
        ))
    }
}

// Each session gets its own stub, so concurrent tests cannot change one another's responses.
final class MockHTTP: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)?
    static let accountJSON = #"{"login":"octocat","avatar_url":"https://avatars.githubusercontent.com/u/1"}"#

    let session: URLSession
    private let id: String

    init(handler: @escaping Handler) {
        id = UUID().uuidString
        MockURLProtocol.handlers.set(id, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Pingit-Test-ID": id]
        session = URLSession(configuration: configuration)
    }

    convenience init(status: Int = 200, body: String = accountJSON, headers: [String: String] = [:]) {
        self.init { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        }
    }

    deinit {
        session.invalidateAndCancel()
        MockURLProtocol.handlers.remove(id)
    }

    var client: GitHubClient { GitHubClient(session: session) }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: MockHTTP.Handler] = [:]

        func set(_ id: String, _ handler: @escaping MockHTTP.Handler) {
            lock.lock()
            defer { lock.unlock() }
            values[id] = handler
        }

        func get(_ id: String) -> MockHTTP.Handler? {
            lock.lock()
            defer { lock.unlock() }
            return values[id]
        }

        func remove(_ id: String) {
            lock.lock()
            defer { lock.unlock() }
            values[id] = nil
        }
    }

    static let handlers = Handlers()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Pingit-Test-ID"),
              let handler = Self.handlers.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            guard let (response, data) = try handler(request) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
