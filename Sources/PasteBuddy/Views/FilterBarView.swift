import PasteBuddyCore
import SwiftUI

struct FilterBarView: View {
    @Bindable var store: PasteBuddyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker(localized("Type"), selection: $store.contentTypeFilter) {
                    Text(localized("Any Type")).tag(nil as ClipboardContentType?)
                    ForEach(ClipboardContentType.allCases) { type in
                        Text(localized(type.displayName)).tag(Optional(type))
                    }
                }
                .frame(maxWidth: 150)
                .accessibilityLabel(localized("Content type filter"))

                Picker(localized("App"), selection: $store.sourceAppFilter) {
                    Text(localized("Any App")).tag(nil as String?)
                    ForEach(store.availableSourceApps, id: \.self) { appName in
                        Text(appName).tag(Optional(appName))
                    }
                }
                .frame(maxWidth: 180)
                .accessibilityLabel(localized("Source app filter"))

                Picker(localized("Device"), selection: $store.deviceFilter) {
                    Text(localized("Any Device")).tag(nil as String?)
                    ForEach(store.availableDevices, id: \.self) { deviceName in
                        Text(deviceName).tag(Optional(deviceName))
                    }
                }
                .frame(maxWidth: 180)
                .accessibilityLabel(localized("Device filter"))

                Picker(localized("Date"), selection: $store.dateFilter) {
                    ForEach(ClipboardDateFilter.allCases) { filter in
                        Text(localized(filter.displayName)).tag(filter)
                    }
                }
                .frame(maxWidth: 150)
                .accessibilityLabel(localized("Copied date filter"))

                Spacer()

                Button {
                    store.clearFilters()
                } label: {
                    Label(localized("Clear Filters"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .disabled(!store.hasActiveFilters)
                .accessibilityHint(localized("Removes all active clipboard filters."))
            }

            if !store.activeFilterSummaries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.activeFilterSummaries) { summary in
                            Button {
                                store.clearFilter(summary.kind)
                            } label: {
                                Label(summary.title, systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(String(format: localized("Remove %@"), summary.title))
                            .accessibilityLabel(String(format: localized("Remove %@"), summary.title))
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(localized("Active clipboard filters"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
