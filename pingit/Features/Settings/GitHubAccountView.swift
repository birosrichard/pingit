import SwiftUI

struct GitHubAccountView: View {
    let account: GitHubAccount

    var body: some View {
        HStack(spacing: 12) {
            // Avatar requests carry no token; the API client accepts only HTTPS avatar URLs.
            AsyncImage(url: account.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .accessibilityLabel("Avatar for \(account.login)")

            VStack(alignment: .leading, spacing: 4) {
                Text("@\(account.login)")
                    .font(.headline)
                    .textSelection(.enabled)
                Label("Connected to GitHub", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


struct GitHubOwnerAvatar: View {
    let owner: String?
    var size: CGFloat = 32
    var fallbackSystemImage = "person.crop.circle.fill"

    var body: some View {
        // This public request is independent of the authenticated GitHub client.
        AsyncImage(url: GitHubAvatar.url(for: owner)) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4))
        .accessibilityHidden(true)
    }
}
