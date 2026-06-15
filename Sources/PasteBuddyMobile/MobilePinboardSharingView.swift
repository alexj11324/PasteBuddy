import PasteBuddyCore
import SwiftUI

public struct MobilePinboardSharingView: View {
    @Bindable private var store: PasteBuddyStore
    private let pinboardID: UUID

    @State private var accessMode: PinboardShareAccessMode = .invitationOnly
    @State private var defaultPermission: PinboardSharePermission = .readOnly
    @State private var inviteName = ""
    @State private var inviteEmail = ""
    @State private var invitePermission: PinboardSharePermission = .readOnly
    @State private var generatedShareToken: String?

    public init(store: PasteBuddyStore, pinboardID: UUID) {
        self.store = store
        self.pinboardID = pinboardID
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let pinboard {
                    Section("Share Settings") {
                        LabeledContent("Pinboard") {
                            Text(pinboard.name)
                        }
                        LabeledContent("Readiness") {
                            Text(store.syncReadiness.displayName)
                                .foregroundStyle(store.canManageSharedPinboards ? .green : .orange)
                        }
                        Text(store.canManageSharedPinboards ? "Shared pinboards are encrypted and ready." : "Configure CloudKit sync and turn on Shared Pinboards before sharing.")
                            .foregroundStyle(.secondary)
                        if let error = store.lastErrorMessage {
                            Text(error)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Access") {
                        Picker("Access Mode", selection: $accessMode) {
                            ForEach(PinboardShareAccessMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Picker("Default Permission", selection: $defaultPermission) {
                            ForEach(PinboardSharePermission.allCases) { permission in
                                Text(permission.displayName).tag(permission)
                            }
                        }
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

                    Section("Participants") {
                        if pinboard.sharing?.participants.isEmpty != false {
                            Text("No participants")
                                .foregroundStyle(.secondary)
                        } else if let participants = pinboard.sharing?.participants {
                            ForEach(participants) { participant in
                                VStack(alignment: .leading, spacing: 8) {
                                    LabeledContent(participant.displayName) {
                                        Button("Remove") {
                                            store.removeParticipant(pinboardID: pinboardID, participantID: participant.id)
                                        }
                                    }
                                    if let emailAddress = participant.emailAddress, !emailAddress.isEmpty {
                                        Text(emailAddress)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
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
                                }
                            }
                        }
                    }

                    Section("Invite Participant") {
                        TextField("Name", text: $inviteName)
                        TextField("Email", text: $inviteEmail)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            #endif
                        Picker("Permission", selection: $invitePermission) {
                            ForEach(PinboardSharePermission.allCases) { permission in
                                Text(permission.displayName).tag(permission)
                            }
                        }
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

                    if pinboard.sharing != nil {
                        Section {
                            Button("Stop Sharing", role: .destructive) {
                                store.stopSharingPinboard(pinboardID)
                                generatedShareToken = nil
                                syncDraftsFromSharing()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Pinboard", systemImage: "pin.slash", description: Text("Not found"))
                }
            }
            .navigationTitle("Share Pinboard")
            .onAppear(perform: syncDraftsFromSharing)
        }
    }

    private var pinboard: Pinboard? {
        store.snapshot.pinboards.first(where: { $0.id == pinboardID })
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
