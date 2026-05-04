import SwiftUI

/// One-time username claim shown after sign-up (and as a safety net inside
/// `PublishSheet`). Single text field, debounced live availability check,
/// and a Claim button that's enabled only while the input is `.available`.
///
/// Lives inside the parent's NavigationStack — the publish sheet provides
/// the surrounding chrome — so this view doesn't add its own toolbar.
struct UsernamePickerView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var vm = UsernameClaimViewModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 4) {
                    Text("@")
                        .foregroundStyle(.secondary)
                        .font(.body.monospaced())
                    TextField("yourname", text: $vm.input)
                        .font(.body.monospaced())
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .onChange(of: vm.input) { _, value in
                            vm.onInputChange(value)
                        }
                }
                if let hint = vm.hint {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: hint.kind))
                        Text(hint.text)
                    }
                    .font(.footnote)
                    .foregroundStyle(color(for: hint.kind))
                } else if vm.isWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(vm.phase == .claiming ? "Claiming…" : "Checking…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Pick your username")
            } footer: {
                Text("Lowercase letters, numbers, and underscores. 3–30 characters. You can't change this later.")
            }

            Section {
                Button {
                    Task {
                        guard let user = auth.currentUser else { return }
                        if let claimed = await vm.claim(userId: user.id) {
                            auth.setClaimedUsername(claimed)
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if vm.phase == .claiming {
                            ProgressView()
                        } else {
                            Text("Claim").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!vm.canSubmit || vm.isWorking)
            }
        }
        .onAppear { fieldFocused = true }
    }

    private func icon(for kind: UsernameClaimViewModel.HintKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: UsernameClaimViewModel.HintKind) -> Color {
        switch kind {
        case .success: return .green
        case .warning: return .orange
        }
    }
}
