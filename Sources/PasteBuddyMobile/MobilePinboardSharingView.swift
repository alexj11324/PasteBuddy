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
                    Section("action.share_settings") {
                        LabeledContent("label.pinboard") {
                            Text(pinboard.name)
                        }
                        LabeledContent("label.readiness") {
                            Text(store.syncReadiness.displayName)
                                .foregroundStyle(store.canManageSharedPinboards ? .green : .orange)
                        }
                        Text(store.canManageSharedPinboards ? "message.shared_pinboards_are_ready" : "message.configure_cloudkit_sync_and_turn_on_shared")
                            .foregroundStyle(.secondary)
                        if let error = store.lastErrorMessage {
                            Text(error)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("label.access") {
                        Picker("label.access_mode", selection: $accessMode) {
                            ForEach(PinboardShareAccessMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Picker("label.default_permission", selection: $defaultPermission) {
                            ForEach(PinboardSharePermission.allCases) { permission in
                                Text(permission.displayName).tag(permission)
                            }
                        }
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

                    Section("label.participants") {
                        if pinboard.sharing?.participants.isEmpty != false {
                            Text("label.no_participants")
                                .foregroundStyle(.secondary)
                        } else if let participants = pinboard.sharing?.participants {
                            ForEach(participants) { participant in
                                VStack(alignment: .leading, spacing: 8) {
                                    LabeledContent(participant.displayName) {
                                        Button("action.remove") {
                                            store.removeParticipant(pinboardID: pinboardID, participantID: participant.id)
                                        }
                                    }
                                    if let emailAddress = participant.emailAddress, !emailAddress.isEmpty {
                                        Text(emailAddress)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
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
                                }
                            }
                        }
                    }

                    Section("action.invite_participant") {
                        TextField("label.name", text: $inviteName)
                        TextField("label.email", text: $inviteEmail)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            #endif
                        Picker("label.permission", selection: $invitePermission) {
                            ForEach(PinboardSharePermission.allCases) { permission in
                                Text(permission.displayName).tag(permission)
                            }
                        }
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

                    if pinboard.sharing != nil {
                        Section {
                            Button("action.stop_sharing", role: .destructive) {
                                store.stopSharingPinboard(pinboardID)
                                generatedShareToken = nil
                                syncDraftsFromSharing()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("label.pinboard", systemImage: "pin.slash", description: Text("label.not_found"))
                }
            }
            .navigationTitle("action.share_pinboard")
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
