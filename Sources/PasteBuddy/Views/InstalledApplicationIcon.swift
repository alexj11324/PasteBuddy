import Foundation
import SwiftUI

struct InstalledApplicationIcon: View {
    var application: InstalledApplication?

    @ViewBuilder
    var body: some View {
        if let iconResource {
            Image(iconResource.name, bundle: iconResource.bundle)
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "app")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
    }

    private var iconResource: (name: String, bundle: Bundle)? {
        guard let application,
              let bundle = Bundle(url: application.url) else {
            return nil
        }

        if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
           !iconName.isEmpty {
            return (iconName, bundle)
        }

        guard let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !iconFile.isEmpty else {
            return nil
        }
        let iconName = URL(fileURLWithPath: iconFile).deletingPathExtension().lastPathComponent
        return (iconName, bundle)
    }
}
