import Foundation
import Testing

struct GitHubPullRequestTests {
    @Test func decodesDashboardValues() throws {
        let json = #"""
        {
          "id":"PR_1", "number":42, "title":"Fix menu bar", "url":"https://github.com/octocat/pingit/pull/42",
          "repository":{"id":"R_1", "nameWithOwner":"octocat/pingit", "url":"https://github.com/octocat/pingit"},
          "authorLogin":"octocat", "isDraft":true, "createdAt":"2026-10-20T09:00:00Z", "updatedAt":"2026-10-21T09:00:00Z",
          "reviewStatus":"changesRequested", "checkStatus":"pending",
          "reviewRequests":[{"user":{"login":"reviewer"}},{"team":{"organizationLogin":"acme","slug":"macos"}}]
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(GitHubPullRequest.self, from: Data(json.utf8))
        #expect(pr.id == "PR_1")
        #expect(pr.number == 42)
        #expect(pr.title == "Fix menu bar")
        #expect(pr.url.absoluteString == "https://github.com/octocat/pingit/pull/42")
        #expect(pr.repository == GitHubRepository(id: "R_1", nameWithOwner: "octocat/pingit",
                                                 url: URL(string: "https://github.com/octocat/pingit")!))
        #expect(pr.authorLogin == "octocat")
        #expect(pr.isDraft)
        #expect(pr.updatedAt == Date(timeIntervalSince1970: 1_792_573_200))
        #expect(pr.reviewStatus == .changesRequested)
        #expect(pr.checkStatus == .pending)
        #expect(pr.reviewRequests == [.user(login: "reviewer"), .team(organizationLogin: "acme", slug: "macos")])
    }

    @Test func unavailableValuesRemainDistinctFromEmptyRequests() throws {
        let json = #"""
        {"id":"PR_2", "number":1, "title":"New PR", "url":"https://github.com/a/b/pull/1",
         "repository":{"id":"R_2", "nameWithOwner":"a/b", "url":"https://github.com/a/b"},
         "authorLogin":null, "isDraft":false, "createdAt":"2026-10-20T09:00:00Z", "updatedAt":"2026-10-21T09:00:00Z"}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(GitHubPullRequest.self, from: Data(json.utf8))
        #expect(pr.authorLogin == nil)
        #expect(pr.reviewStatus == nil)
        #expect(pr.latestReviews == nil)
        #expect(pr.checkStatus == nil)
        #expect(pr.reviewRequests == nil)
        let withEmptyRequests = json.dropLast() + #", "reviewRequests":[]}"#
        let loaded = try decoder.decode(GitHubPullRequest.self, from: Data(withEmptyRequests.utf8))
        #expect(loaded.reviewRequests == [])
    }

    @Test(arguments: ["reviewRequired", "approved", "changesRequested", "unknown"])
    func decodesReviewStatus(value: String) throws {
        let status = try JSONDecoder().decode(GitHubReviewStatus.self, from: Data("\"\(value)\"".utf8))
        #expect(status.rawValue == value)
    }

    @Test func reviewerDetailsRoundTrip() throws {
        let details = GitHubLatestReviews(reviews: [
            GitHubPullRequestReview(id: "review", authorLogin: nil, state: .dismissed)
        ], limitations: [.missingIdentity, .reviewerLimit])
        #expect(try JSONDecoder().decode(GitHubLatestReviews.self, from: JSONEncoder().encode(details)) == details)
    }

    @Test(arguments: ["pending", "success", "failure"])
    func decodesCheckStatus(value: String) throws {
        let status = try JSONDecoder().decode(GitHubCheckStatus.self, from: Data("\"\(value)\"".utf8))
        #expect(status.rawValue == value)
    }
}
