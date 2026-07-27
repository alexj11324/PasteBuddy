import PasteBuddyCore
import SwiftUI

struct ClipboardPanelFiltersMenu: View {
    @Bindable var store: PasteBuddyStore

    var body: some View {
        Menu {
            Picker("label.type", selection: $store.contentTypeFilter) {
                Text("label.any_type").tag(nil as ClipboardContentType?)
                ForEach(ClipboardContentType.allCases) { type in
                    Text(NSLocalizedString(type.displayName, comment: "")).tag(Optional(type))
                }
            }

            Picker(
                "label.app",
                selection: Binding(
                    get: { store.sourceAppFilter },
                    set: { store.setSourceAppFilter($0) }
                )
            ) {
                Text("label.any_app").tag(nil as String?)
                ForEach(store.availableSourceApps, id: \.self) { appName in
                    Text(appName).tag(Optional(appName))
                }
            }

            Picker("label.device", selection: $store.deviceFilter) {
                Text("label.any_device").tag(nil as String?)
                ForEach(store.availableDevices, id: \.self) { deviceName in
                    Text(deviceName).tag(Optional(deviceName))
                }
            }

            Picker("label.date", selection: $store.dateFilter) {
                ForEach(ClipboardDateFilter.allCases) { filter in
                    Text(NSLocalizedString(filter.displayName, comment: "")).tag(filter)
                }
            }

            Button("action.clear_filters") {
                store.clearFilters()
            }
            .disabled(!store.hasActiveFilters)
        } label: {
            Label("label.filters", systemImage: "line.3.horizontal.decrease")
        }
        .help(NSLocalizedString("label.filters", comment: ""))
        .accessibilityLabel(NSLocalizedString("label.filters", comment: ""))
    }
}
