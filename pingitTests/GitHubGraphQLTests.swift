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
        await #expect(throws: GitHubAPIError.rateLimited) { try await execute(http) }
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
