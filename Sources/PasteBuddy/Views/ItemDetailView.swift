import AppKit
import PasteBuddyCore
import SwiftUI

struct ItemDetailView: View {
    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    @State private var draftTitle = ""
    @State private var draftLabels = ""
    @State private var draftText = ""
    @State private var rerunningOCRItemIDs: Set<UUID> = []

    var body: some View {
        Group {
            if let item = store.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(for: item)
                        preview(for: item)
                        metadata(for: item)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: item.id) {
                    draftTitle = item.title
                    draftLabels = item.labels.joined(separator: ", ")
                    draftText = item.payload.text ?? ""
                }
                .onAppear {
                    draftTitle = item.title
                    draftLabels = item.labels.joined(separator: ", ")
                    draftText = item.payload.text ?? ""
                }
            } else {
                ContentUnavailableView(
                    localized("Select an Item"),
                    systemImage: "sidebar.right",
                    description: Text(localized("Clipboard details, OCR text, and pinning actions appear here."))
                )
            }
        }
    }

    private func header(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .accessibilityLabel(localized("Clipboard item title"))
                    .onSubmit {
                        store.renameSelectedItem(to: draftTitle)
                    }

                Button("Save") {
                    store.renameSelectedItem(to: draftTitle)
                }
                .help(NSLocalizedString("Save Title", comment: ""))
            }

            HStack(alignment: .firstTextBaseline) {
                TextField("Labels", text: $draftLabels)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(localized("Clipboard item labels"))
                    .accessibilityHint(localized("Separate labels with commas."))
                    .onSubmit {
                        store.setLabels(parsedLabels, for: item.id)
                    }

                Button("Save") {
                    store.setLabels(parsedLabels, for: item.id)
                    draftLabels = store.selectedItem?.labels.joined(separator: ", ") ?? ""
                }
                .help(NSLocalizedString("Save Labels", comment: ""))
            }

            if !item.labels.isEmpty {
                HStack(spacing: 8) {
                    ForEach(item.labels, id: \.self) { label in
                        Button {
                            store.removeLabel(label, from: item.id)
                            draftLabels = store.selectedItem?.labels.joined(separator: ", ") ?? ""
                        } label: {
                            Label(label, systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(format: localized("Remove label %@"), label))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(localized("Clipboard item labels"))
            }

            Picker(
                "Reusable Type",
                selection: Binding(
                    get: { store.selectedItem?.reuseCategory ?? item.reuseCategory },
                    set: { store.setReuseCategory($0, for: item.id) }
                )
            ) {
                ForEach(ClipboardReuseCategory.allCases) { category in
                    Label(localized(category.displayName), systemImage: category.systemImageName)
                        .tag(category)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(localized("Reusable content type"))

            HStack {
                Button {
                    PasteboardWriter.copy(item)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    pasteItem(item, format: store.defaultPasteFormat)
                } label: {
                    Label("Paste to Active App", systemImage: "arrow.down.doc")
                }

                Menu {
                    if let url = item.openableURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                        }
                    }

                    Button("Copy as Plain Text") {
                        PasteboardWriter.copy(item, format: .plainText)
                    }
                    Button("Paste as Plain Text") {
                        pasteItem(item, format: .plainText)
                    }

                    Menu("Pin") {
                        ForEach(store.snapshot.pinboards) { pinboard in
                            Button(pinboard.name) {
                                store.pinItem(item.id, to: pinboard.id)
                            }
                        }
                    }

                    if case .pinboard(let pinboardID) = store.selectedScope {
                        Button("Remove from Pinboard") {
                            store.removeItem(item.id, fromPinboard: pinboardID)
                        }
                    }

                    Button("Undo Delete") {
                        store.undoLastDeletion()
                    }
                    .disabled(!store.canUndoDelete)

                    Divider()

                    Button("Delete", role: .destructive) {
                        store.removeItem(item.id)
                    }
                    .accessibilityHint(localized("Removes this clipboard item from history and pinboards. Use Undo Delete to restore it."))
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var parsedLabels: [String] {
        draftLabels
            .split(separator: ",")
            .map(String.init)
    }

    @ViewBuilder
    private func preview(for item: ClipboardItem) -> some View {
        switch item.contentType {
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draftText)
                    .font(.body.monospaced())
                    .frame(minHeight: 240)
                    .border(.quaternary)
                    .accessibilityLabel(localized("Clipboard text body"))
                    .accessibilityHint(localized("Edit the saved text, then choose Save Text."))

                Button("Save Text") {
                    store.updateTextItem(item.id, to: draftText)
                }
                .accessibilityHint(localized("Saves edits back to clipboard history."))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .url:
            VStack(alignment: .leading, spacing: 8) {
                Text(item.payload.urlString ?? "")
                    .textSelection(.enabled)
                if let value = item.payload.urlString, let url = URL(string: value) {
                    Link("Open Link", destination: url)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .file:
            Text(item.payload.allFileURLStrings.joined(separator: "\n"))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .image:
            VStack(alignment: .leading, spacing: 12) {
                if item.payload.hasImageAsset {
                    CachedDetailImagePreview(item: item, imageDataProvider: store.imageData)
                        .id(ClipboardImageCache.thumbnailCacheKey(for: item, maxPixelSize: 1_600))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Local OCR")
                            .font(.headline)
                        Spacer()
                        Button {
                            rerunOCR(for: item)
                        } label: {
                            Label(
                                rerunningOCRItemIDs.contains(item.id) ? "Re-running OCR" : "Re-run OCR",
                                systemImage: "text.viewfinder"
                            )
                        }
                        .disabled(item.payload.imageData == nil || rerunningOCRItemIDs.contains(item.id))
                    }
                    Text(item.ocrState.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let text = item.payload.ocrText, !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .font(.body.monospaced())
                    } else {
                        Text("Recognized screenshot text will appear here after Apple's local Vision OCR finishes.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        case .mixed:
            VStack(alignment: .leading, spacing: 12) {
                Text(ClipboardPlainTextRenderer.plainText(for: item))
                    .textSelection(.enabled)
                    .font(.body.monospaced())
                if let html = item.payload.htmlString, !html.isEmpty {
                    LabeledContent("HTML") {
                        Text(html.singleLinePreview)
                            .textSelection(.enabled)
                    }
                }
                if !item.payload.allFileURLStrings.isEmpty {
                    LabeledContent("Files") {
                        Text(item.payload.allFileURLStrings.joined(separator: "\n"))
                            .textSelection(.enabled)
                    }
                }
                if item.payload.imageData != nil {
                    Label("Includes image data", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func metadata(for item: ClipboardItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Text(localized(item.contentType.displayName))
            }
            GridRow {
                Text("Reusable Type").foregroundStyle(.secondary)
                Text(localized(item.reuseCategory.displayName))
            }
            GridRow {
                Text("Source").foregroundStyle(.secondary)
                Text(item.sourceAppName)
            }
            GridRow {
                Text("Device").foregroundStyle(.secondary)
                Text(item.deviceName)
            }
            GridRow {
                Text("Created").foregroundStyle(.secondary)
                Text(item.createdAt.formatted(date: .abbreviated, time: .standard))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Clipboard item metadata"))
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func pasteItem(_ item: ClipboardItem, format: PasteFormat) {
        Task { @MainActor in
            let result = await directPasteItem(item, format)
            store.recordDirectPasteResult(result)
        }
    }

    private func rerunOCR(for item: ClipboardItem) {
        guard let imageData = item.payload.imageData else { return }
        rerunningOCRItemIDs.insert(item.id)
        store.markOCRPending(for: item.id)
        Task {
            do {
                let text = try await OCRService().recognizeText(in: imageData)
                await MainActor.run {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        store.markOCRFailed(String(localized: "No Chinese or English text was recognized."), for: item.id)
                    } else {
                        store.updateOCRText(trimmed, for: item.id)
                    }
                    rerunningOCRItemIDs.remove(item.id)
                }
            } catch {
                await MainActor.run {
                    store.markOCRFailed(error.localizedDescription, for: item.id)
                    rerunningOCRItemIDs.remove(item.id)
                }
            }
        }
    }
}

private struct CachedDetailImagePreview: View {
    let item: ClipboardItem
    let imageDataProvider: @MainActor (ClipboardItem) async -> Data?
    @State private var image: NSImage?
    @State private var loadedImageData: Data?

    var body: some View {
        Group {
            if let image = image ?? ClipboardImageCache.cachedThumbnail(
                for: item,
                imageData: loadedImageData,
                maxPixelSize: maxPixelSize
            ) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(item.contentType.detailPreviewTint.opacity(0.10))
                    Image(systemName: "photo")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(item.contentType.detailPreviewTint)
                }
                .frame(height: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(localized("Captured image preview"))
        .accessibilityHint(localized("Recognized local OCR text appears below the image when available."))
        .task(id: ClipboardImageCache.thumbnailCacheKey(for: item, maxPixelSize: maxPixelSize)) {
            image = ClipboardImageCache.cachedThumbnail(
                for: item,
                imageData: loadedImageData,
                maxPixelSize: maxPixelSize
            )
            guard image == nil else { return }

            let imageData: Data?
            if let loadedImageData {
                imageData = loadedImageData
            } else {
                imageData = await imageDataProvider(item)
            }
            loadedImageData = imageData
            let loadedImage = await ClipboardImageCache.thumbnail(
                for: item,
                imageData: imageData,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }

    private var maxPixelSize: Int {
        1_600
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private extension ClipboardContentType {
    var detailPreviewTint: Color {
        switch self {
        case .text:
            .blue
        case .url:
            .teal
        case .image:
            .green
        case .file:
            .orange
        case .mixed:
            .purple
        }
    }
}
