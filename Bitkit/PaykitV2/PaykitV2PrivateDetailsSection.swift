#if DEBUG
    import SwiftUI

    /// Demo: on a connected contact's screen, whether Bitkit shared its private payment details (its Paykit v0.2
    /// Private Payment List) with the contact, and whether the contact shared theirs.
    struct PaykitV2PrivateDetailsSection: View {
        let details: PaykitV2PrivateDetails
        let contactName: String

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("contacts__private_details_title"), textColor: .white64)
                    .padding(.bottom, 4)

                row(
                    label: t("contacts__private_details_yours"),
                    value: details.sharedByBitkit
                        ? t("contacts__private_details_shared_with", variables: ["name": contactName])
                        : t("contacts__private_details_sharing_with", variables: ["name": contactName]),
                    isDone: details.sharedByBitkit,
                    pendingIndicator: true
                )
                .accessibilityIdentifier("ContactPrivateDetailsShared")
                .accessibilityValue(details.sharedByBitkit ? "shared" : "sharing")

                CustomDivider()

                row(
                    label: t("contacts__private_details_theirs", variables: ["name": contactName.localizedUppercase]),
                    value: details.sharedByContact
                        ? t("contacts__private_details_received")
                        : t("contacts__private_details_not_received"),
                    isDone: details.sharedByContact,
                    pendingIndicator: false
                )
                .accessibilityIdentifier("ContactPrivateDetailsReceived")
                .accessibilityValue(details.sharedByContact ? "received" : "waiting")

                CustomDivider()

                CaptionBText(t("contacts__private_details_note"), textColor: .white50)
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: details)
        }

        private func row(label: String, value: String, isDone: Bool, pendingIndicator: Bool) -> some View {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(label, textColor: .white64)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    BodySSBText(value, textColor: isDone ? .textPrimary : .white50)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isDone {
                    Image("check-mark")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.greenAccent)
                        .transition(.opacity)
                } else if pendingIndicator {
                    ActivityIndicator(size: 16)
                }
            }
            .padding(.vertical, 16)
            .accessibilityElement(children: .combine)
        }
    }

    /// Demo: where the payer of a request Bitkit sends pays, chosen on the request's details screen.
    enum PaykitV2PayTo: String, CaseIterable, CustomStringConvertible {
        /// A new address of Bitkit's wallet, carried in the request.
        case newAddress
        /// Bitkit's Private Payment List, which the contact holds (`RequestDestination.any`).
        case privateDetails

        var description: String {
            switch self {
            case .newAddress: t("wallet__payment_request_pay_to_new_address")
            case .privateDetails: t("wallet__payment_request_pay_to_private")
            }
        }
    }

    #Preview {
        VStack(spacing: 32) {
            PaykitV2PrivateDetailsSection(details: PaykitV2PrivateDetails(sharedByBitkit: false, sharedByContact: false),
                                          contactName: "Alice")
            PaykitV2PrivateDetailsSection(details: PaykitV2PrivateDetails(sharedByBitkit: true, sharedByContact: true),
                                          contactName: "Alice")
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
#endif
