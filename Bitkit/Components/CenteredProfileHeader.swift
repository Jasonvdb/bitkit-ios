import SwiftUI

struct CenteredProfileHeader: View {
    let truncatedKey: String
    let name: String
    let bio: String
    let imageUrl: String?
    var avatarSize: CGFloat = 96
    var showBio: Bool = true
    var showDivider: Bool = true
    /// Set on own Profile screen for E2E; omit on contact previews so IDs stay unique.
    var nameAccessibilityIdentifier: String?
    var notesAccessibilityIdentifier: String?
    var keyAccessibilityIdentifier: String?
    /// Shows a name field in place of the name, for a profile whose name the user gives.
    var editableName: Binding<String>?
    var editableNamePlaceholder: String = t("profile__create_name_placeholder")

    var body: some View {
        VStack(spacing: 16) {
            CaptionMText(truncatedKey, textColor: .white64)
                .accessibilityIdentifierIfPresent(keyAccessibilityIdentifier)

            avatarView

            if let editableName {
                ProfileNameField(
                    name: editableName,
                    accessibilityId: nameAccessibilityIdentifier ?? "ProfileHeaderNameField",
                    placeholder: editableNamePlaceholder
                )
            } else {
                Text(name.uppercased())
                    .font(Fonts.black(size: 44))
                    .kerning(-1)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifierIfPresent(nameAccessibilityIdentifier)
            }

            if showBio, !bio.isEmpty {
                BodyMText(bio, textColor: .white64)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifierIfPresent(notesAccessibilityIdentifier)
            }

            if showDivider {
                CustomDivider()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let imageUrl {
            PubkyImage(uri: imageUrl, size: avatarSize)
        } else {
            Circle()
                .fill(Color.gray5)
                .frame(width: avatarSize, height: avatarSize)
                .overlay {
                    Image("user-square")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white32)
                        .frame(width: avatarSize * 0.5, height: avatarSize * 0.5)
                }
        }
    }
}

#Preview {
    VStack {
        CenteredProfileHeader(
            truncatedKey: "3RSD...W5XG",
            name: "Satoshi Nakamoto",
            bio: "Authored the Bitcoin white paper, developed Bitcoin, mined first block.",
            imageUrl: nil
        )

        Spacer()
    }
    .padding(.horizontal, 16)
    .background(Color.customBlack)
    .preferredColorScheme(.dark)
}
