import SwiftUI

struct SaveTemplateSheet: View {
    var defaultName: String
    var onSave: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var didSave = false
    @State private var errorMessage: String?

    init(defaultName: String, onSave: @escaping (String) -> Bool) {
        self.defaultName = defaultName
        self.onSave = onSave
        _name = State(initialValue: defaultName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Template Name", text: $name)
                        .font(.cucuSerif(16, weight: .regular))
                        .foregroundStyle(Color.cucuInk)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } header: {
                    CucuSectionLabel(text: "Name")
                } footer: {
                    Text("Saves a reusable local copy of this canvas design. Your current draft is not changed.")
                        .font(.cucuSans(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                }

                if didSave {
                    Section {
                        Label("Template saved", systemImage: "checkmark.circle.fill")
                            .font(.cucuSerif(15, weight: .semibold))
                            .foregroundStyle(Color.cucuMoss)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.cucuSans(12, weight: .medium))
                            .foregroundStyle(Color.cucuCherry)
                    }
                }
            }
            .cucuFormBackdrop()
            .cucuSheetTitle("Save as Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .font(.cucuSerif(16, weight: .bold))
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        errorMessage = nil
        didSave = false
        if onSave(trimmedName) {
            didSave = true
        } else {
            errorMessage = "Couldn't save this template. Try again."
        }
    }
}
