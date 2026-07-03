import SwiftUI

struct NewTextItemSheet: View {
    @State private var title = ""
    @State private var text = ""
    @State private var errorMessage: String?
    let onSave: (String?, String) -> String?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("label.new_text_item")
                .font(.headline)

            TextField("label.title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .border(.quaternary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("action.cancel", role: .cancel) {
                    onCancel()
                }
                Button("action.create") {
                    errorMessage = onSave(title, text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
