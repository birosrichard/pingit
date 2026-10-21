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
