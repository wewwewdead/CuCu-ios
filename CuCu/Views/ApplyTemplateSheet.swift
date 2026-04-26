import SwiftData
import SwiftUI

struct ApplyTemplateSheet: View {
    @Query(sort: \ProfileTemplate.updatedAt, order: .reverse) private var templates: [ProfileTemplate]

    var onApply: (ProfileTemplate) -> Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pendingTemplate: ProfileTemplate?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Templates",
                        systemImage: "square.on.square",
                        description: Text("Save a canvas as a template first.")
                    )
                } else {
                    Section {
                        ForEach(templates) { template in
                            Button {
                                pendingTemplate = template
                            } label: {
                                TemplateRow(template: template)
                            }
                        }
                        .onDelete(perform: deleteTemplates)
                    } header: {
                        CucuSectionLabel(text: "Saved Templates")
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
            .cucuSheetTitle("Apply Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
                if !templates.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                            .font(.cucuSerif(16, weight: .semibold))
                    }
                }
            }
            .alert(
                "Replace current canvas?",
                isPresented: confirmationPresented,
                actions: {
                    Button("Cancel", role: .cancel) {
                        pendingTemplate = nil
                    }
                    Button("Apply", role: .destructive) {
                        applyPendingTemplate()
                    }
                },
                message: {
                    Text("This replaces the current canvas design. The draft title stays the same.")
                }
            )
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingTemplate != nil },
            set: { isPresented in
                if !isPresented {
                    pendingTemplate = nil
                }
            }
        )
    }

    private func applyPendingTemplate() {
        guard let template = pendingTemplate else { return }
        pendingTemplate = nil
        errorMessage = nil
        if onApply(template) {
            dismiss()
        } else {
            errorMessage = "Couldn't apply that template."
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        let store = TemplateStore(context: context)
        for index in offsets {
            store.deleteTemplate(templates[index])
        }
    }
}

// `CreateDraftFromTemplateSheet` lived here in the prototype as the
// "New From Template" sheet for the now-removed drafts page. The
// product is single-document — there's no separate drafts list, so
// no UI ever called this sheet. Removed entirely; if multi-document
// returns later, restore from git history.

private struct TemplateRow: View {
    let template: ProfileTemplate

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.cucuMatcha)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cucuInk, lineWidth: 1)
                Image(systemName: "square.on.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.cucuCard)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.cucuSerif(16, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .lineLimit(1)
                Text(template.previewSummary ?? "Saved design")
                    .font(.cucuSans(12, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
                    .lineLimit(1)
                Text(template.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.cucuMono(10, weight: .regular))
                    .tracking(1)
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.cucuInkFaded)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
