import Foundation

struct GitHubAccount: Decodable, Equatable, Sendable {
    let login: String
    let avatarURL: URL

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

enum GitHubAPIError: Error, LocalizedError, Equatable {
    case invalidToken
    case forbidden
    case rateLimited
    case networkUnavailable
    case unexpectedResponse
    case invalidRequest
    case httpError(statusCode: Int)
    case graphQLFailure
    case partialData
    case missingData

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
        case .invalidRequest:
            "Couldn’t encode the GitHub request."
        case .httpError:
            "GitHub returned an HTTP error. Try again later."
        case .graphQLFailure:
            "GitHub couldn’t complete the query. Check repository access and try again."
        case .partialData:
            "GitHub returned incomplete data. Try again later."
        case .missingData:
            "GitHub returned no query data. Try again later."
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
        let request = try authenticatedRequest(url: URL(string: "https://api.github.com/user")!, token: token)
        let (data, response) = try await responseData(for: request)
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

    // The caller loads the existing Keychain credential, as for authenticatedAccount.
    func graphQL<Response: Decodable & Sendable, Variables: Encodable & Sendable>(
        query: String,
        variables: Variables,
        token: String,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        try Task.checkCancellation()
        var request = try authenticatedRequest(url: URL(string: "https://api.github.com/graphql")!, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        } catch {
            throw GitHubAPIError.invalidRequest
        }
        let (data, response) = try await responseData(for: request)
        switch response.statusCode {
        case 200:
            break
        case 401:
            throw GitHubAPIError.invalidToken
        case 403, 429:
            let message = (try? JSONDecoder().decode(APIMessage.self, from: data))?.message.lowercased() ?? ""
            let errors = (try? JSONDecoder().decode(GraphQLMetadata.self, from: data))?.errors ?? []
            if response.statusCode == 429 || isRateLimited(response) || message.contains("rate limit")
                || errors.contains(where: { $0.isRateLimited }) {
                throw GitHubAPIError.rateLimited
            }
            throw GitHubAPIError.forbidden
        default:
            throw GitHubAPIError.httpError(statusCode: response.statusCode)
        }

        // Inspect errors before decoding typed data: failed fields may be null even
        // when the requested response type requires them. Never expose server messages.
        guard let metadata = try? JSONDecoder().decode(GraphQLMetadata.self, from: data) else {
            throw GitHubAPIError.unexpectedResponse
        }
        if let errors = metadata.errors, !errors.isEmpty {
            if isRateLimited(response) || errors.contains(where: { $0.isRateLimited }) {
                throw GitHubAPIError.rateLimited
            }
            throw metadata.hasData ? GitHubAPIError.partialData : GitHubAPIError.graphQLFailure
        }
        guard metadata.hasData else { throw GitHubAPIError.missingData }
        guard let envelope = try? JSONDecoder().decode(GraphQLData<Response>.self, from: data) else {
            throw GitHubAPIError.unexpectedResponse
        }
        try Task.checkCancellation()
        return envelope.data
    }

    private func authenticatedRequest(url: URL, token: String) throws -> URLRequest {
        // Reject whitespace/control characters before constructing an Authorization header.
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw GitHubAPIError.invalidToken
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("pingit", forHTTPHeaderField: "User-Agent")

        return request
    }

    private func responseData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        return (data, response)
    }

    private func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            || response.value(forHTTPHeaderField: "Retry-After") != nil
    }

    private struct GraphQLRequest<Variables: Encodable>: Encodable {
        let query: String
        let variables: Variables
    }

    private struct GraphQLData<Value: Decodable>: Decodable {
        let data: Value
    }

    private struct GraphQLMetadata: Decodable {
        let hasData: Bool
        let errors: [QueryError]?

        enum CodingKeys: String, CodingKey { case data, errors }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasData = try container.contains(.data) && !container.decodeNil(forKey: .data)
            errors = try container.decodeIfPresent([QueryError].self, forKey: .errors)
        }
    }

    private struct QueryError: Decodable {
        let message: String
        let type: String?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let code: String?
        }

        var isRateLimited: Bool {
            type == "RATE_LIMITED" || extensions?.code == "RATE_LIMITED"
                || message.lowercased().contains("rate limit")
        }
    }

    private struct APIMessage: Decodable {
        let message: String
    }

    // API requests have fixed HTTPS destinations; never forward credentials to a redirect target.
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
