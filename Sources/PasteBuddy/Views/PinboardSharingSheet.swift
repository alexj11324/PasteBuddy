import PasteBuddyCore
import SwiftUI

struct PinboardSharingSheet: View {
    @Bindable var store: PasteBuddyStore
    let pinboardID: UUID
    let onDone: () -> Void

    @State private var accessMode: PinboardShareAccessMode = .invitationOnly
    @State private var defaultPermission: PinboardSharePermission = .readOnly
    @State private var inviteName = ""
    @State private var inviteEmail = ""
    @State private var invitePermission: PinboardSharePermission = .readOnly
    @State private var generatedShareToken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pinboard {
                header(pinboard)
                readinessSection
                sharingControls(pinboard)
                participantControls(pinboard)
                footer(pinboard)
            } else {
                ContentUnavailableView("label.pinboard", systemImage: "pin.slash", description: Text("label.not_found"))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: syncDraftsFromSharing)
    }

    private var pinboard: Pinboard? {
        store.snapshot.pinboards.first(where: { $0.id == pinboardID })
    }

    private func header(_ pinboard: Pinboard) -> some View {
        HStack {
            Label("action.share_pinboard", systemImage: "person.2.badge.plus")
                .font(.headline)
            Spacer()
            Text(pinboard.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.syncReadiness.displayName, systemImage: store.canManageSharedPinboards ? "checkmark.shield" : "exclamationmark.triangle")
                .foregroundStyle(store.canManageSharedPinboards ? .green : .orange)
            Text(store.canManageSharedPinboards ? "message.shared_pinboards_are_encrypted_and_ready" : "message.configure_cloudkit_sync_and_turn_on_shared")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = store.lastErrorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func sharingControls(_ pinboard: Pinboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("label.access_mode", selection: $accessMode) {
                ForEach(PinboardShareAccessMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("label.default_permission", selection: $defaultPermission) {
                ForEach(PinboardSharePermission.allCases) { permission in
                    Text(permission.displayName).tag(permission)
                }
            }
            .pickerStyle(.segmented)

            Button(pinboard.sharing == nil ? "action.start_sharing" : "label.update_sharing") {
                generatedShareToken = store.sharePinboard(
                    pinboardID,
                    accessMode: accessMode,
                    defaultPermission: defaultPermission
                )
                syncDraftsFromSharing()
            }
            .disabled(!store.canManageSharedPinboards)

            if let generatedShareToken {
                LabeledContent("action.share_link_token") {
                    Text(generatedShareToken)
                        .textSelection(.enabled)
                        .monospaced()
                }
                Text("message.pastebuddy_stores_only_the_hash_of_this")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func participantControls(_ pinboard: Pinboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("label.participants")
                .font(.subheadline.weight(.semibold))

            if pinboard.sharing?.participants.isEmpty != false {
                Text("label.no_participants")
                    .foregroundStyle(.secondary)
            } else if let participants = pinboard.sharing?.participants {
                ForEach(participants) { participant in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(participant.displayName)
                            if let emailAddress = participant.emailAddress, !emailAddress.isEmpty {
                                Text(emailAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("label.permission", selection: Binding(
                            get: { participant.permission },
                            set: { permission in
                                store.updateParticipantPermission(
                                    pinboardID: pinboardID,
                                    participantID: participant.id,
                                    permission: permission
                                )
                            }
                        )) {
                            ForEach(PinboardSharePermission.allCases) { permission in
                                Text(permission.displayName).tag(permission)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button("action.remove") {
                            store.removeParticipant(pinboardID: pinboardID, participantID: participant.id)
                        }
                    }
                }
            }

            Divider()

            TextField("label.name", text: $inviteName)
                .textFieldStyle(.roundedBorder)
            TextField("label.email", text: $inviteEmail)
                .textFieldStyle(.roundedBorder)
            Picker("label.permission", selection: $invitePermission) {
                ForEach(PinboardSharePermission.allCases) { permission in
                    Text(permission.displayName).tag(permission)
                }
            }
            .pickerStyle(.segmented)

            Button("action.invite_participant") {
                _ = store.inviteParticipant(
                    to: pinboardID,
                    displayName: inviteName,
                    emailAddress: normalizedInviteEmail,
                    permission: invitePermission
                )
                inviteName = ""
                inviteEmail = ""
            }
            .disabled(!store.canManageSharedPinboards || inviteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func footer(_ pinboard: Pinboard) -> some View {
        HStack {
            if pinboard.sharing != nil {
                Button("action.stop_sharing", role: .destructive) {
                    store.stopSharingPinboard(pinboardID)
                    generatedShareToken = nil
                    syncDraftsFromSharing()
                }
            }
            Spacer()
            Button("action.done") {
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var normalizedInviteEmail: String? {
        let trimmed = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func syncDraftsFromSharing() {
        guard let sharing = pinboard?.sharing else {
            accessMode = .invitationOnly
            defaultPermission = .readOnly
            return
        }
        accessMode = sharing.accessMode
        defaultPermission = sharing.defaultPermission
    }
}
