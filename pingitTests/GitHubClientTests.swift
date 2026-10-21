import Foundation
import Testing

struct GitHubClientTests {
    @Test func validatesAccountAndRequest() async throws {
        let http = MockHTTP { request in
            #expect(request.url?.absoluteString == "https://api.github.com/user")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "pingit")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(MockHTTP.accountJSON.utf8))
        }
        let account = try await http.client.authenticatedAccount(token: "test-token")
        #expect(account.login == "octocat")
        #expect(account.avatarURL.absoluteString == "https://avatars.githubusercontent.com/u/1")
    }

    @Test func unauthorizedToken() async {
        let http = MockHTTP(status: 401, body: #"{"message":"Never echo test-token"}"#)
        await #expect(throws: GitHubAPIError.invalidToken) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
    }

    @Test(arguments: ["", "bad\r\nheader", "has space", "🔑"])
    func rejectsMalformedTokens(token: String) async {
        let http = MockHTTP { _ in
            Issue.record("Malformed tokens must not reach networking")
            throw URLError(.badURL)
        }
        await #expect(throws: GitHubAPIError.invalidToken) {
            try await http.client.authenticatedAccount(token: token)
        }
    }

    @Test(arguments: [403, 429]) func primaryRateLimit(status: Int) async {
        let http = MockHTTP(status: status, headers: ["X-RateLimit-Remaining": "0"])
        await #expect(throws: GitHubAPIError.rateLimited) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
    }

    @Test(arguments: [true, false]) func secondaryRateLimit(withRetryHeader: Bool) async {
        let http = MockHTTP(status: 403, body: #"{"message":"You have exceeded a secondary rate limit."}"#,
                            headers: withRetryHeader ? ["Retry-After": "60"] : [:])
        do {
            _ = try await http.client.authenticatedAccount(token: "test-token")
            Issue.record("Expected rate limit")
        } catch {
            let api = error as? GitHubAPIError
            if withRetryHeader {
                #expect((api?.retryDeadline?.timeIntervalSinceNow ?? 0) > 55)
            } else {
                #expect(api == .rateLimited)
            }
        }
    }

    @Test func forbiddenIsNotInvalidToken() async {
        let http = MockHTTP(status: 403, body: #"{"message":"Access denied"}"#)
        await #expect(throws: GitHubAPIError.forbidden) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
    }

    @Test func networkFailureIsSanitized() async {
        let http = MockHTTP { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "Secret test-token"])
        }
        await #expect(throws: GitHubAPIError.networkUnavailable) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
        #expect(!GitHubAPIError.networkUnavailable.localizedDescription.contains("test-token"))
    }

    @Test func cancellationStaysCancellation() async {
        let http = MockHTTP { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
    }

    @Test(arguments: [201, 302, 404, 500]) func unexpectedStatus(status: Int) async {
        let http = MockHTTP(status: status)
        await #expect(throws: GitHubAPIError.unexpectedResponse) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
    }

    @Test(arguments: [
        "not JSON", "{}", #"{"login":"","avatar_url":"https://avatars.githubusercontent.com/u/1"}"#,
        #"{"login":"octocat","avatar_url":"http://avatars.githubusercontent.com/u/1"}"#,
        #"{"login":"octocat","avatar_url":"https://user:password@example.com/avatar"}"#
    ])
    func unexpectedBody(body: String) async {
        let http = MockHTTP(body: body)
        await #expect(throws: GitHubAPIError.unexpectedResponse) {
            try await http.client.authenticatedAccount(token: "test-token")
        }
    }

    @Test func redirectsAreRejected() {
        let http = MockHTTP()
        let task = http.session.dataTask(with: URL(string: "https://api.github.com/user")!)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/user")!,
                                       statusCode: 302, httpVersion: nil, headerFields: nil)!
        GitHubClient.RejectRedirects().urlSession(http.session, task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://example.com/steal")!)) { request in
                #expect(request == nil)
            }
    }
}
