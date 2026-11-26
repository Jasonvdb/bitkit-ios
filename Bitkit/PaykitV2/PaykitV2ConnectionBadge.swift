#if DEBUG
    import SwiftUI

    /// Demo: whether Bitkit and a contact have added each other on Paykit v0.2, shown under the contact's name.
    struct PaykitV2ConnectionBadge: View {
        let connection: PaykitV2ContactConnection
        let contactName: String

        var body: some View {
            HStack(spacing: 8) {
                switch connection {
                case .connected:
                    Circle()
                        .fill(Color.greenAccent)
                        .frame(width: 8, height: 8)
                    CaptionBText(t("contacts__connection_connected"), textColor: .greenAccent)
                        .lineLimit(1)
                case .waiting:
                    ActivityIndicator(size: 12)
                    CaptionBText(t("contacts__connection_waiting", variables: ["name": contactName]), textColor: .white64)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(connection == .connected ? Color.green16 : Color.white08))
            .animation(.easeInOut(duration: 0.25), value: connection)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ContactConnectionStatus")
            .accessibilityValue(connection == .connected ? "connected" : "waiting")
        }
    }

    #Preview {
        VStack(spacing: 16) {
            PaykitV2ConnectionBadge(connection: .waiting, contactName: "Arkade")
            PaykitV2ConnectionBadge(connection: .connected, contactName: "Arkade")
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
#endif
