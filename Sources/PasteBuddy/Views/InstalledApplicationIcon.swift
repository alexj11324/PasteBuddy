import QuickLookThumbnailing
import SwiftUI

struct InstalledApplicationIcon: View {
    var application: InstalledApplication?

    @Environment(\.displayScale) private var displayScale
    @State private var iconImage: CGImage?

    var body: some View {
        Group {
            if let iconImage {
                Image(decorative: iconImage, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .task(id: application?.url) {
            await loadIcon()
        }
    }

    @MainActor
    private func loadIcon() async {
        iconImage = nil
        guard let application else { return }

        let request = QLThumbnailGenerator.Request(
            fileAt: application.url,
            size: CGSize(width: 48, height: 48),
            scale: displayScale,
            representationTypes: [.icon]
        )
        request.iconMode = true

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            iconImage = representation.cgImage
        } catch {
            // The SF Symbol remains visible when Quick Look cannot resolve an icon.
        }
    }
}
