import Foundation

struct GitHubAccount: Decodable, Equatable, Sendable {
    let login: String
    let avatarURL: URL

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

enum GitHubAPIError: Error, LocalizedError {
    case invalidToken
    case forbidden
    case rateLimited
    case networkUnavailable
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "This token is invalid or expired. Create a new token and try again."
        case .forbidden:
            "GitHub denied access. Check your token and account access policies."
        case .rateLimited:
            "GitHub’s rate limit was reached. Wait before trying again."
        case .networkUnavailable:
            "Couldn’t reach GitHub. Check your internet connection and try again."
        case .unexpectedResponse:
            "GitHub returned an unexpected response. Try again later."
        }
    }
}

struct GitHubClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        }
    }

    func authenticatedAccount(token: String) async throws -> GitHubAccount {
        // Reject whitespace/control characters before constructing an Authorization header.
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw GitHubAPIError.invalidToken
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("pingit", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Transport errors may contain request details. Never surface the original error.
            throw GitHubAPIError.networkUnavailable
        }
        guard let response = response as? HTTPURLResponse else {
            throw GitHubAPIError.unexpectedResponse
        }
        switch response.statusCode {
        case 200:
            guard let account = try? JSONDecoder().decode(GitHubAccount.self, from: data),
                  !account.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.avatarURL.scheme?.lowercased() == "https",
                  account.avatarURL.host != nil,
                  account.avatarURL.user == nil, account.avatarURL.password == nil else {
                throw GitHubAPIError.unexpectedResponse
            }
            return account
        case 401:
            throw GitHubAPIError.invalidToken
        case 403, 429:
            let message = (try? JSONDecoder().decode(APIMessage.self, from: data))?.message.lowercased() ?? ""
            if response.statusCode == 429
                || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil
                || message.contains("rate limit") {
                throw GitHubAPIError.rateLimited
            }
            throw GitHubAPIError.forbidden
        default:
            throw GitHubAPIError.unexpectedResponse
        }
    }

    private struct APIMessage: Decodable {
        let message: String
    }

    // /user has a fixed HTTPS destination; never forward credentials to a redirect target.
    final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
