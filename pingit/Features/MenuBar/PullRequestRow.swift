import SwiftUI

struct PullRequestRow: View {
    let presentation: PullRequestRowPresentation
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let url = presentation.browserURL {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
                    .focused($isFocused)
                    .accessibilityHint("Opens this pull request on GitHub")
            } else {
                content
            }
        }
        .help(presentation.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.accessibilityLabel) Updated \(presentation.updatedAt.formatted(date: .abbreviated, time: .shortened)).")
        .onHover { isHovered = $0 }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: DashboardLayout.avatarSpacing) {
            GitHubOwnerAvatar(owner: presentation.avatarOwner, size: DashboardLayout.avatarSize,
                              fallbackSystemImage: "shippingbox")
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(presentation.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(presentation.compactUpdatedAge(relativeTo: context.date))
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
                    .fixedSize()
                    .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    Text(presentation.repositoryLabel)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(presentation.repositoryLabel)
                    Spacer(minLength: 0)
                    if let attention = presentation.attention {
                        Label(attention.label, systemImage: attention.systemImage)
                            .font(.caption)
                            .foregroundStyle(attention.reason == nil ? Color.secondary : Color.accentColor)
                            .lineLimit(1)
                            .fixedSize()
                            .help(attention.accessibilityLabel)
                    }
                }
                metadata.font(.callout)
                if presentation.browserURL == nil {
                    Label("GitHub link unavailable", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DashboardLayout.rowInset)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background(isHovered && presentation.browserURL != nil ? Color.primary.opacity(0.045) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2)
        }
    }

    @ViewBuilder private var metadata: some View {
        if presentation.authorLabel != nil || presentation.review != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    contextMetadata
                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    diffMetadata
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                    contextMetadata
                    diffMetadata
                }
            }
        } else {
            diffMetadata
        }
    }

    @ViewBuilder private var contextMetadata: some View {
        if let author = presentation.authorLabel {
            Text(author).foregroundStyle(.secondary).lineLimit(1)
        } else if let review = presentation.review {
            Label(review.label, systemImage: review.systemImage)
                .foregroundStyle(metadataColor(review.tone))
                .lineLimit(1)
                .help(presentation.help)
        }
    }

    @ViewBuilder private var diffMetadata: some View {
        if let diff = presentation.diff {
            HStack(spacing: 6) {
                Text(diff.filesLabel).foregroundStyle(.secondary)
                Text(diff.additionsLabel).foregroundStyle(.green)
                Text(diff.deletionsLabel).foregroundStyle(.red)
            }
            .monospacedDigit()
            .help(diff.accessibilityLabel)
        } else {
            Text("Diff unavailable").foregroundStyle(.secondary)
        }
    }

    private func metadataColor(_ tone: PullRequestReviewPresentation.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .positive: .green
        case .caution: .orange
        case .negative: .secondary
        }
    }
}
