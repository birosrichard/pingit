import Foundation
import Testing

struct GitHubPullRequestDiscoveryTests {
    private let account = GitHubAccount(login: "octocat", avatarURL: URL(string: "https://github.com/avatar")!)

    private func authored(_ http: MockHTTP, limit: Int = 200) async throws -> GitHubPullRequestDiscoveryResult {
        try await GitHubPullRequestDiscovery(client: http.client)
            .authoredPullRequests(for: account, token: "test-token", maximumResults: limit)
    }

    private func reviews(_ http: MockHTTP, limit: Int = 200) async throws -> GitHubPullRequestDiscoveryResult {
        try await GitHubPullRequestDiscovery(client: http.client)
            .reviewRequestedPullRequests(for: account, token: "test-token", maximumResults: limit)
    }

    @Test func authoredQueryAndMappingIncludeDrafts() async throws {
        let script = Script([try payload([node(draft: true)])])
        let result = try await authored(script.http)
        let request = try #require(script.requests.first)
        #expect(request.variables.query == "is:pr is:open author:octocat sort:updated-desc")
        #expect(request.variables.first == 50)
        #expect(request.variables.after == nil)
        #expect(!request.variables.includeReviewRequests)
        #expect(request.query.contains("type: ISSUE"))
        #expect(request.query.contains("createdAt updatedAt"))
        #expect(request.query.contains("reviewDecision"))
        #expect(!request.query.contains("statusCheckRollup"))
        let pr = try #require(result.pullRequests.first)
        #expect(pr.id == "PR_1")
        #expect(pr.number == 1)
        #expect(pr.title == "Pull request 1")
        #expect(pr.url.absoluteString == "https://github.com/acme/app/pull/1")
        #expect(pr.repository.nameWithOwner == "acme/app")
        #expect(pr.repository.id == "R_1")
        #expect(pr.authorLogin == "octocat")
        #expect(pr.isDraft)
        #expect(pr.createdAt == Date(timeIntervalSince1970: 1_792_486_800))
        #expect(pr.updatedAt == Date(timeIntervalSince1970: 1_792_573_200))
        #expect(pr.reviewStatus == .unknown && pr.checkStatus == nil && pr.reviewRequests == nil)
        #expect(!result.isTruncated)
        #expect(result.coverageLimitations == [.tokenVisibility])
    }

    @Test(arguments: ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "UNSUPPORTED", "", nil] as [String?])
    func mapsAuthoritativeReviewDecision(decision: String?) async throws {
        var value = node()
        value["reviewDecision"] = decision as Any? ?? NSNull()
        let result = try await authored(MockHTTP(body: try payload([value])))
        let expected: GitHubReviewStatus = switch decision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .unknown
        }
        #expect(result.pullRequests.first?.reviewStatus == expected)
    }

    @Test func usesValidatedAccountRatherThanHardcodedLogin() async throws {
        let script = Script([try payload([node(author: "someone-else")], viewer: "someone-else")])
        let http = script.http
        let result = try await GitHubPullRequestDiscovery(client: http.client).authoredPullRequests(
            for: GitHubAccount(login: "someone-else", avatarURL: account.avatarURL), token: "test-token")
        #expect(result.pullRequests.count == 1)
        #expect(script.requests.first?.variables.query == "is:pr is:open author:someone-else sort:updated-desc")
    }

    @Test func emptySearchPreservesVisibilityWarning() async throws {
        let body = try payload([])
        let a = try await authored(MockHTTP(body: body))
        let r = try await reviews(MockHTTP(body: body))
        #expect(a.pullRequests.isEmpty && r.pullRequests.isEmpty)
        #expect(!a.isTruncated && !r.isTruncated)
        #expect(a.coverageLimitations.contains(.tokenVisibility))
        #expect(r.coverageLimitations == [.tokenVisibility, .directReviewRequestsOnly])
    }

    @Test func directRequestsExcludeDraftsAuthoredClosedAndFulfilled() async throws {
        let script = Script([try payload([
            node(1, author: "someone", reviewers: ["octocat"]),
            node(2, author: "someone", draft: true, reviewers: ["octocat"]),
            node(3, reviewers: ["octocat"]),
            node(4, author: "someone", state: "CLOSED", reviewers: ["octocat"]),
            node(5, author: "someone", state: "MERGED", reviewers: ["octocat"]),
            node(6, author: "someone", reviewers: []),
            node(7, author: "someone", reviewers: ["different-user"])
        ])])
        let result = try await reviews(script.http)
        #expect(result.pullRequests.map(\.id) == ["PR_1"])
        #expect(result.pullRequests.first?.reviewRequests == [.user(login: "octocat")])
        let query = try #require(script.requests.first?.variables.query)
        #expect(query == "is:pr is:open user-review-requested:@me -author:octocat draft:false sort:updated-desc")
        #expect(!query.contains("assignee:") && !query.contains("reviewed-by:"))
        #expect(script.requests.first?.variables.includeReviewRequests == true)
        #expect(result.coverageLimitations.contains(.directReviewRequestsOnly))
    }

    @Test func teamOnlyRequestsAreNotDirectRequests() async throws {
        var team = node(author: "someone", reviewers: [])
        team["reviewRequests"] = ["nodes": [["requestedReviewer": [
            "__typename": "Team", "slug": "macos", "organization": ["login": "acme"]
        ]]], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
        let result = try await reviews(MockHTTP(body: try payload([team])))
        #expect(result.pullRequests.isEmpty)
    }

    @Test func nullableAuthorAndReviewerAndFractionalDate() async throws {
        var value = node(author: nil, updated: "2026-10-21T09:00:00.250Z", reviewers: ["OCTOCAT"])
        var requests = try #require(value["reviewRequests"] as? [String: Any])
        var nodes = try #require(requests["nodes"] as? [[String: Any]])
        nodes.append(["requestedReviewer": NSNull()])
        requests["nodes"] = nodes
        value["reviewRequests"] = requests
        let result = try await reviews(MockHTTP(body: try payload([value])))
        #expect(result.pullRequests.first?.authorLogin == nil)
        #expect(result.pullRequests.first?.updatedAt == Date(timeIntervalSince1970: 1_792_573_200.25))
        #expect(result.pullRequests.count == 1)
    }

    @Test func authoredRechecksStateAndAuthor() async throws {
        let result = try await authored(MockHTTP(body: try payload([
            node(1, state: "CLOSED"), node(2, state: "MERGED"), node(3, author: "someone"), node(4)
        ])))
        #expect(result.pullRequests.map(\.id) == ["PR_4"])
    }

    @Test func cursorPaginationDeduplicatesAndKeepsStableRecentOrder() async throws {
        let script = Script([
            try payload([node(1), node(2)], more: true, cursor: "page-1", count: 4),
            try payload([node(2), node(3, updated: "2026-10-22T09:00:00Z"), node(4)], count: 4)
        ])
        let result = try await authored(script.http)
        #expect(result.pullRequests.map(\.id) == ["PR_3", "PR_1", "PR_2", "PR_4"])
        #expect(script.requests.count == 2)
        #expect(script.requests.map(\.variables.after) == [nil, "page-1"])
        #expect(script.requests.allSatisfy { $0.variables.first == 50 })
        #expect(!result.isTruncated)
    }

    @Test func reviewsAlsoPaginateAndDeduplicate() async throws {
        let script = Script([
            try payload([node(1, author: "someone", reviewers: ["octocat"])], more: true, cursor: "next"),
            try payload([node(1, author: "someone", reviewers: ["octocat"]), node(2, author: "someone", reviewers: ["octocat"])])
        ])
        let result = try await reviews(script.http)
        #expect(result.pullRequests.map(\.id) == ["PR_1", "PR_2"])
        #expect(script.requests.count == 2)
    }

    @Test func resultLimitExposesIncompleteSearch() async throws {
        let script = Script([try payload([node(1), node(2)], more: true, cursor: "next", count: 10)])
        let result = try await authored(script.http, limit: 2)
        #expect(result.pullRequests.count == 2)
        #expect(script.requests.count == 1)
        #expect(script.requests.first?.variables.first == 2)
        #expect(result.truncationReasons == [.resultLimit])
    }

    @Test func exactExhaustedLimitIsNotTruncated() async throws {
        let result = try await authored(MockHTTP(body: try payload([node()])), limit: 1)
        #expect(!result.isTruncated)
    }

    @Test func duplicatesDoNotConsumeResultBudget() async throws {
        let script = Script([
            try payload([node(1), node(1)], more: true, cursor: "next"),
            try payload([node(2)])
        ])
        let result = try await authored(script.http, limit: 2)
        #expect(result.pullRequests.map(\.id) == ["PR_1", "PR_2"])
        #expect(script.requests.map(\.variables.first) == [2, 1])
    }

    @Test func requestBoundPreventsUnboundedDuplicatePages() async throws {
        let pages = try (1...20).map { try payload([node()], more: true, cursor: "cursor-\($0)", count: 30) }
        let script = Script(pages)
        let result = try await authored(script.http)
        #expect(script.requests.count == 20)
        #expect(result.pullRequests.count == 1)
        #expect(result.truncationReasons == [.pageLimit])
    }

    @Test func gitHubSearchCapIsExplicitEvenWithHasNextPageFalse() async throws {
        let result = try await authored(MockHTTP(body: try payload([node()], count: 1001)))
        #expect(result.truncationReasons == [.searchLimit])
    }

    @Test(arguments: [nil, "", "same"] as [String?])
    func missingOrRepeatedCursorStopsSafely(cursor: String?) async throws {
        let script = Script([
            try payload([node(1)], more: true, cursor: "same"),
            try payload([node(2)], more: true, cursor: cursor)
        ])
        let result = try await authored(script.http)
        #expect(script.requests.count == 2)
        #expect(result.truncationReasons == [.invalidCursor])
    }

    @Test func nestedReviewRequestLimitIsNotAnEmptyOrCompleteList() async throws {
        let confirmed = node(1, author: "someone", reviewers: ["octocat"], moreReviewers: true)
        let uncertain = node(2, author: "someone", reviewers: ["someone-else"], moreReviewers: true)
        let result = try await reviews(MockHTTP(body: try payload([confirmed, uncertain])))
        #expect(result.pullRequests.map(\.id) == ["PR_1"])
        #expect(result.pullRequests.first?.reviewRequests == nil)
        #expect(result.truncationReasons == [.reviewRequestLimit])
    }

    @Test(arguments: ["id", "number", "title", "url", "repository", "state", "isDraft", "createdAt", "updatedAt"])
    func requiredFieldsCannotSilentlyDisappear(field: String) async throws {
        var value = node()
        value[field] = nil
        let http = MockHTTP(body: try payload([value]))
        await #expect(throws: GitHubAPIError.unexpectedResponse) { try await authored(http) }
    }

    @Test(arguments: ["bad-date", "", "2026-99-99T99:00:00Z"])
    func invalidDatesAreSanitized(date: String) async throws {
        let http = MockHTTP(body: try payload([node(updated: date)]))
        await #expect(throws: GitHubAPIError.unexpectedResponse) { try await authored(http) }
    }

    @Test func nullSearchNodeIsExplicitMissingData() async throws {
        let http = MockHTTP(body: try payload([NSNull()]))
        await #expect(throws: GitHubAPIError.missingData) { try await authored(http) }
    }

    @Test func missingReviewConnectionFailsInsteadOfPretendingFulfilled() async throws {
        let http = MockHTTP(body: try payload([node(author: "someone")]))
        await #expect(throws: GitHubAPIError.partialData) { try await reviews(http) }
    }

    @Test(arguments: [401, 403, 429, 500]) func failureDuringPagination(status: Int) async throws {
        let script = Script([try payload([node()], more: true, cursor: "next"), "{}"], statuses: [200, status])
        let expected: GitHubAPIError = switch status {
        case 401: .invalidToken
        case 403: .forbidden
        case 429: .rateLimited
        default: .httpError(statusCode: status)
        }
        await #expect(throws: expected) { try await authored(script.http) }
        #expect(script.requests.count == 2)
    }

    @Test func permissionRelatedGraphQLErrorsAreNotEmptySuccess() async {
        let http = MockHTTP(body: #"{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by personal access token"}]}"#)
        await #expect(throws: GitHubAPIError.graphQLFailure) { try await authored(http) }
        #expect(GitHubAPIError.graphQLFailure.localizedDescription.contains("access"))
    }

    @Test func partialPermissionFailureDuringPaginationFailsWholeOperation() async throws {
        let script = Script([try payload([node()], more: true, cursor: "next"),
                             #"{"data":{"search":null},"errors":[{"type":"FORBIDDEN","message":"Denied"}]}"#])
        await #expect(throws: GitHubAPIError.partialData) { try await authored(script.http) }
    }

    @Test(arguments: [0, -1, 1001, Int.max]) func invalidLimitsDoNotSendRequests(limit: Int) async {
        let http = MockHTTP { _ in Issue.record("Invalid limit reached networking"); throw URLError(.badURL) }
        await #expect(throws: GitHubDiscoveryError.invalidLimit) { try await authored(http, limit: limit) }
    }

    @Test func accountMismatchIsExplicit() async throws {
        let http = MockHTTP(body: try payload([], viewer: "different-user"))
        await #expect(throws: GitHubDiscoveryError.accountMismatch) { try await reviews(http) }
    }

    @Test func loginCannotInjectSearchQualifiers() async {
        let http = MockHTTP { _ in Issue.record("Invalid login reached networking"); throw URLError(.badURL) }
        await #expect(throws: GitHubDiscoveryError.invalidAccount) {
            try await GitHubPullRequestDiscovery(client: http.client).authoredPullRequests(
                for: GitHubAccount(login: "octocat OR author:anyone", avatarURL: account.avatarURL), token: "test-token")
        }
    }

    @Test func cancellationOnSecondPageRemainsCancellation() async throws {
        let first = try payload([node()], more: true, cursor: "next")
        let (started, signal) = AsyncStream<Void>.makeStream()
        let http = MockHTTP { request in
            let body = try Script.decode(request)
            if body.variables.after != nil {
                signal.yield(())
                signal.finish()
                return nil
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(first.utf8))
        }
        let task = Task { try await authored(http) }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledDiscoveryDoesNotReadNetwork() async {
        let http = MockHTTP { _ in Issue.record("Cancelled discovery reached networking"); throw URLError(.badURL) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reviews(http)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func node(
        _ number: Int = 1, author: String? = "octocat", draft: Bool = false, state: String = "OPEN",
        updated: String = "2026-10-21T09:00:00Z", reviewers: [String]? = nil, moreReviewers: Bool = false
    ) -> [String: Any] {
        var value: [String: Any] = [
            "__typename": "PullRequest", "id": "PR_\(number)", "number": number,
            "title": "Pull request \(number)", "url": "https://github.com/acme/app/pull/\(number)",
            "repository": ["id": "R_1", "nameWithOwner": "acme/app", "url": "https://github.com/acme/app"],
            "author": author.map { ["login": $0] } as Any? ?? NSNull(), "state": state, "isDraft": draft,
            "createdAt": "2026-10-20T09:00:00Z", "updatedAt": updated
        ]
        if let reviewers {
            value["reviewRequests"] = [
                "nodes": reviewers.map { ["requestedReviewer": ["__typename": "User", "login": $0]] },
                "pageInfo": ["hasNextPage": moreReviewers, "endCursor": moreReviewers ? "review-next" as Any : NSNull()]
            ]
        }
        return value
    }

    private func payload(_ nodes: [Any], more: Bool = false, cursor: String? = nil, count: Int? = nil, viewer: String = "octocat") throws -> String {
        let object: [String: Any] = ["data": ["viewer": ["login": viewer], "search": [
            "nodes": nodes, "issueCount": count ?? nodes.count,
            "pageInfo": ["hasNextPage": more, "endCursor": cursor as Any? ?? NSNull()]
        ]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private final class Script: @unchecked Sendable {
        struct Request: Decodable, Sendable {
            let query: String
            let variables: Variables
            struct Variables: Decodable, Sendable {
                let query: String
                let first: Int
                let after: String?
                let includeReviewRequests: Bool
            }
        }

        private let lock = NSLock()
        private let bodies: [String]
        private let statuses: [Int]
        private var recorded: [Request] = []

        init(_ bodies: [String], statuses: [Int] = []) { self.bodies = bodies; self.statuses = statuses }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var http: MockHTTP {
            MockHTTP { request in
                let decoded = try Self.decode(request)
                self.lock.lock()
                defer { self.lock.unlock() }
                let index = self.recorded.count
                self.recorded.append(decoded)
                guard index < self.bodies.count else {
                    Issue.record("Discovery exceeded scripted request count")
                    throw URLError(.badServerResponse)
                }
                let status = index < self.statuses.count ? self.statuses[index] : 200
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                        Data(self.bodies[index].utf8))
            }
        }

        static func decode(_ request: URLRequest) throws -> Request {
            if let data = request.httpBody { return try JSONDecoder().decode(Request.self, from: data) }
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return try JSONDecoder().decode(Request.self, from: data)
        }
    }
}
