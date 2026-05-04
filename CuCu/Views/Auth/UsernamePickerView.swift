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
    /// Drives the underline pulse so the moss tint flashes briefly
    /// when an availability check resolves to `.success`. Reset on
    /// every input change so subsequent re-checks pulse anew.
    @State private var underlinePulse: Bool = false

    var body: some View {
        Form {
            Section {
                inputRow
                hintRow
            } header: {
                CucuSectionLabel(text: "Pick your username")
            } footer: {
                Text("Lowercase letters, numbers, and underscores. 3–30 characters. You can't change this later.")
                    .font(.cucuEditorial(12, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
            }

            Section {
                HStack {
                    Spacer()
                    claimChip
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .cucuFormBackdrop()
        .onAppear { fieldFocused = true }
        .onChange(of: vm.hint?.kind) { _, kind in
            if kind == .success {
                withAnimation(.easeInOut(duration: 0.5)) { underlinePulse = true }
            } else {
                underlinePulse = false
            }
        }
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("@")
                    .font(.cucuMono(15, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
                TextField("yourname", text: $vm.input)
                    .font(.cucuMono(15, weight: .regular))
                    .foregroundStyle(Color.cucuInk)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onChange(of: vm.input) { _, value in
                        vm.onInputChange(value)
                    }
            }
            Rectangle()
                .fill(underlinePulse && vm.hint?.kind == .success && !vm.isWorking
                      ? Color.cucuMoss
                      : Color.cucuInk)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var hintRow: some View {
        if let hint = vm.hint {
            HStack(spacing: 6) {
                Image(systemName: icon(for: hint.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color(for: hint.kind))
                Text(hint.text)
                    .font(.cucuEditorial(13, italic: true))
                    .foregroundStyle(color(for: hint.kind))
            }
        } else if vm.isWorking {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.cucuInkSoft)
                Text(vm.phase == .claiming ? "Claiming…" : "Checking…")
                    .font(.cucuEditorial(13, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
            }
        }
    }

    private var claimChip: some View {
        let disabled = !vm.canSubmit || vm.isWorking
        return Button {
            Task {
                guard let user = auth.currentUser else { return }
                if let claimed = await vm.claim(userId: user.id) {
                    CucuHaptics.success()
                    auth.setClaimedUsername(claimed)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if vm.phase == .claiming {
                    ProgressView()
                        .tint(Color.cucuMoss)
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Claim")
                        .font(.cucuSerif(15, weight: .semibold))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minWidth: 120)
            .foregroundStyle(Color.cucuMoss)
            .background(Capsule().fill(Color.cucuMossSoft))
            .overlay(Capsule().strokeBorder(Color.cucuMoss, lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }

    private func icon(for kind: UsernameClaimViewModel.HintKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: UsernameClaimViewModel.HintKind) -> Color {
        switch kind {
        case .success: return .cucuMoss
        case .warning: return .cucuBurgundy
        }
    }
}
