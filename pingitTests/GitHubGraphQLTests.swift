import Foundation
import Testing

struct GitHubGraphQLTests {
    private struct ViewerData: Decodable, Sendable, Equatable {
        struct Viewer: Decodable, Sendable, Equatable { let login: String }
        let viewer: Viewer
    }

    private func execute(_ http: MockHTTP) async throws -> ViewerData {
        try await http.client.graphQL(query: "query { viewer { login } }", variables: [String: String](), token: "test-token")
    }

    @Test @MainActor func authenticatedRequestWithVariables() async throws {
        let query = "query($login: String!) { viewer: user(login: $login) { login } }"
        let http = MockHTTP { request in
            #expect(request.url?.absoluteString == "https://api.github.com/graphql")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "pingit")
            let body: Data
            if let data = request.httpBody {
                body = data
            } else {
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                body = try Data(reading: stream)
            }
            let object = try JSONSerialization.jsonObject(with: body)
            let payload = try #require(object as? [String: Any])
            #expect(payload["query"] as? String == query)
            #expect(payload["variables"] as? [String: String] == ["login": "octocat"])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                     headerFields: ["X-RateLimit-Remaining": "0"])!,
                    Data(#"{"data":{"viewer":{"login":"octocat"}}}"#.utf8))
        }
        let keychain = MockKeychain()
        try keychain.store.save("test-token")
        let savedToken = try keychain.store.load()
        let token = try #require(savedToken)
        let result: ViewerData = try await http.client.graphQL(query: query, variables: ["login": "octocat"], token: token)
        #expect(result.viewer.login == "octocat")
        // The last allowed successful response is still usable with remaining == 0.
        #expect(keychain.reads == 1)
    }

    @Test(arguments: [
        #"{"errors":[{"message":"Secret test-token"}]}"#,
        #"{"data":null,"errors":[{"message":"Invalid query"}]}"#
    ]) func graphQLErrorsWithHTTP200(body: String) async {
        await #expect(throws: GitHubAPIError.graphQLFailure) { try await execute(MockHTTP(body: body)) }
        #expect(!GitHubAPIError.graphQLFailure.localizedDescription.contains("test-token"))
    }

    @Test(arguments: [
        #"{"data":{"viewer":null},"errors":[{"message":"Forbidden"}]}"#,
        #"{"data":{"viewer":{"login":"octocat"}},"errors":[{"message":"Other field failed"}]}"#
    ]) func partialDataIsRejectedBeforeTypedDecoding(body: String) async {
        await #expect(throws: GitHubAPIError.partialData) { try await execute(MockHTTP(body: body)) }
    }

    @Test(arguments: ["{}", #"{"data":null}"#, #"{"errors":[]}"#])
    func missingData(body: String) async {
        await #expect(throws: GitHubAPIError.missingData) { try await execute(MockHTTP(body: body)) }
    }

    @Test func unauthorized() async {
        await #expect(throws: GitHubAPIError.invalidToken) { try await execute(MockHTTP(status: 401)) }
    }

    @Test func rateLimitWithoutHeaders() async {
        await #expect(throws: GitHubAPIError.rateLimited) { try await execute(MockHTTP(status: 429)) }
    }

    @Test func forbidden() async {
        await #expect(throws: GitHubAPIError.forbidden) { try await execute(MockHTTP(status: 403)) }
    }

    @Test(arguments: [302, 404, 500, 502]) func httpErrors(status: Int) async {
        await #expect(throws: GitHubAPIError.httpError(statusCode: status)) {
            try await execute(MockHTTP(status: status))
        }
    }

    @Test(arguments: [200, 403, 429]) func headerRateLimits(status: Int) async {
        let http = MockHTTP(status: status, body: #"{"errors":[{"message":"Limit reached"}]}"#,
                            headers: ["X-RateLimit-Remaining": "0"])
        await #expect(throws: GitHubAPIError.rateLimited) { try await execute(http) }
    }

    @Test(arguments: [200, 403]) func secondaryRateLimits(status: Int) async {
        let http = MockHTTP(status: status, body: #"{"errors":[{"message":"Limit reached"}]}"#,
                            headers: ["Retry-After": "60"])
        do {
            _ = try await execute(http)
            Issue.record("Expected a rate limit deadline")
        } catch {
            let deadline = (error as? GitHubAPIError)?.retryDeadline
            #expect(deadline != nil)
            #expect((deadline?.timeIntervalSinceNow ?? 0) > 55)
        }
    }

    @Test(arguments: [
        #"{"errors":[{"message":"Limit reached","type":"RATE_LIMITED"}]}"#,
        #"{"errors":[{"message":"Limit reached","extensions":{"code":"RATE_LIMITED"}}]}"#,
        #"{"data":{"viewer":null},"errors":[{"message":"Secondary rate limit exceeded"}]}"#
    ]) func graphQLRateLimits(body: String) async {
        for status in [200, 403] {
            await #expect(throws: GitHubAPIError.rateLimited) {
                try await execute(MockHTTP(status: status, body: body))
            }
        }
    }

    @Test func networkFailureIsSanitized() async {
        let http = MockHTTP { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "Secret test-token"])
        }
        await #expect(throws: GitHubAPIError.networkUnavailable) { try await execute(http) }
    }

    @Test(arguments: ["not JSON", "[]", #"{"data":{"viewer":null}}"#,
                      #"{"data":{"viewer":{"login":42}}}"#, #"{"errors":"bad"}"#])
    func malformedResponse(body: String) async {
        await #expect(throws: GitHubAPIError.unexpectedResponse) { try await execute(MockHTTP(body: body)) }
    }

    @Test func transportCancellation() async {
        let http = MockHTTP { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await execute(http) }
    }

    @Test func cancellationDuringRequest() async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let http = MockHTTP { _ in
            continuation.yield(())
            continuation.finish()
            return nil // Keep URLSession suspended until the task cancels it.
        }
        let task = Task { try await execute(http) }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledTaskDoesNotSendRequest() async {
        let http = MockHTTP { _ in
            Issue.record("Cancelled task must not send a request")
            throw URLError(.badURL)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await execute(http)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func invalidVariablesAreSanitized() async {
        struct InvalidVariables: Encodable, Sendable {
            func encode(to encoder: any Encoder) throws {
                throw NSError(domain: "Secret test-token", code: 1)
            }
        }
        let http = MockHTTP { _ in
            Issue.record("Invalid variables must not reach networking")
            throw URLError(.badURL)
        }
        await #expect(throws: GitHubAPIError.invalidRequest) {
            try await http.client.graphQL(query: "query {}", variables: InvalidVariables(),
                                          token: "test-token", as: ViewerData.self)
        }
    }
}

private extension Data {
    init(reading stream: InputStream) throws {
        self.init()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return }
            append(buffer, count: count)
        }
    }
}

extension GitHubGraphQLTests {
    @Test func retryHeadersChooseTheLatestReliableDeadline() throws {
        let now = Date(timeIntervalSince1970: 1000)
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: 429,
                            httpVersion: nil, headerFields: headers)!
        }
        #expect(GitHubClient.retryDeadline(response(["Retry-After": "120"]), now: now) == now + 120)
        #expect(GitHubClient.retryDeadline(response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000",
                                                    "Retry-After": "120"]), now: now) == Date(timeIntervalSince1970: 2000))
        #expect(GitHubClient.retryDeadline(response(["Retry-After": "Thu, 01 Jan 1970 00:30:00 GMT"]), now: now)
                == Date(timeIntervalSince1970: 1800))
        #expect(GitHubClient.retryDeadline(response(["Retry-After": "nan", "X-RateLimit-Reset": "infinity"]), now: now) == nil)
        #expect(GitHubClient.retryDeadline(response(["Retry-After": "-1"]), now: now) == nil)
        #expect(GitHubClient.retryDeadline(response(["X-RateLimit-Remaining": "1", "X-RateLimit-Reset": "2000"]), now: now) == nil)
    }

    @Test(arguments: [true, false])
    func rateGateStopsLaterPagesButAllowsOtherTokens(successfulLastRequest: Bool) async throws {
        let counter = HTTPRequestCounter()
        let reset = Date().addingTimeInterval(3600)
        let http = MockHTTP { request in
            let count = counter.increment()
            let limited = request.value(forHTTPHeaderField: "Authorization") == "Bearer limited-fixture"
            if limited {
                #expect(count == 1) // Any later request for this token must be stopped before transport.
                return (HTTPURLResponse(url: request.url!, statusCode: successfulLastRequest ? 200 : 429,
                    httpVersion: nil, headerFields: ["X-RateLimit-Remaining": "0",
                                                     "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))])!,
                        Data((successfulLastRequest ? #"{"data":{"viewer":{"login":"octocat"}}}"# : "{}").utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"viewer":{"login":"octocat"}}}"#.utf8))
        }
        let client = http.client
        func query(_ token: String) async throws -> ViewerData {
            try await client.graphQL(query: "query { viewer { login } }", variables: [String: String](), token: token)
        }
        if successfulLastRequest {
            let data = try await query("limited-fixture")
            #expect(data.viewer.login == "octocat")
        } else {
            do { _ = try await query("limited-fixture"); Issue.record("Expected primary limit") }
            catch { #expect((error as? GitHubAPIError)?.retryDeadline != nil) }
        }
        for _ in 0..<3 {
            do { _ = try await query("limited-fixture"); Issue.record("Expected cached restriction") }
            catch { #expect((error as? GitHubAPIError)?.retryDeadline != nil) }
        }
        let data = try await query("healthy-fixture")
        #expect(data.viewer.login == "octocat")
        #expect(counter.value == 2)
    }
}

private final class HTTPRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

extension GitHubGraphQLTests {
    @Test func cachedSecondaryLimitWithoutHeadersRetainsExponentialBackoffSemantics() async {
        let counter = HTTPRequestCounter()
        let http = MockHTTP { request in
            _ = counter.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let client = http.client
        for _ in 0..<3 {
            await #expect(throws: GitHubAPIError.rateLimited) {
                let _: ViewerData = try await client.graphQL(query: "query { viewer { login } }",
                    variables: [String: String](), token: "fixture")
            }
        }
        #expect(counter.value == 1)
    }
}
