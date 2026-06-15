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
                ContentUnavailableView("Pinboard", systemImage: "pin.slash", description: Text("Not found"))
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
            Label("Share Pinboard", systemImage: "person.2.badge.plus")
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
            Text(store.canManageSharedPinboards ? "Shared pinboards are encrypted and ready." : "Configure CloudKit sync and turn on Shared Pinboards before sharing.")
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
            Picker("Access Mode", selection: $accessMode) {
                ForEach(PinboardShareAccessMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Default Permission", selection: $defaultPermission) {
                ForEach(PinboardSharePermission.allCases) { permission in
                    Text(permission.displayName).tag(permission)
                }
            }
            .pickerStyle(.segmented)

            Button(pinboard.sharing == nil ? "Start Sharing" : "Update Sharing") {
                generatedShareToken = store.sharePinboard(
                    pinboardID,
                    accessMode: accessMode,
                    defaultPermission: defaultPermission
                )
                syncDraftsFromSharing()
            }
            .disabled(!store.canManageSharedPinboards)

            if let generatedShareToken {
                LabeledContent("Share link token") {
                    Text(generatedShareToken)
                        .textSelection(.enabled)
                        .monospaced()
                }
                Text("PasteBuddy stores only the hash of this token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func participantControls(_ pinboard: Pinboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Participants")
                .font(.subheadline.weight(.semibold))

            if pinboard.sharing?.participants.isEmpty != false {
                Text("No participants")
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
                        Picker("Permission", selection: Binding(
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
                        Button("Remove") {
                            store.removeParticipant(pinboardID: pinboardID, participantID: participant.id)
                        }
                    }
                }
            }

            Divider()

            TextField("Name", text: $inviteName)
                .textFieldStyle(.roundedBorder)
            TextField("Email", text: $inviteEmail)
                .textFieldStyle(.roundedBorder)
            Picker("Permission", selection: $invitePermission) {
                ForEach(PinboardSharePermission.allCases) { permission in
                    Text(permission.displayName).tag(permission)
                }
            }
            .pickerStyle(.segmented)

            Button("Invite Participant") {
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
                Button("Stop Sharing", role: .destructive) {
                    store.stopSharingPinboard(pinboardID)
                    generatedShareToken = nil
                    syncDraftsFromSharing()
                }
            }
            Spacer()
            Button("Done") {
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
