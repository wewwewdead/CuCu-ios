import SwiftUI

struct SignUpView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TextField("you@example.com", text: $email)
                    .font(.cucuMono(14, weight: .regular))
                    .foregroundStyle(Color.cucuInk)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                CucuSectionLabel(text: "Email")
            }
            Section {
                SecureField("At least 8 characters", text: $password)
                    .font(.cucuMono(14, weight: .regular))
                    .foregroundStyle(Color.cucuInk)
            } header: {
                CucuSectionLabel(text: "Password")
            }

            Section {
                HStack {
                    Spacer()
                    submitChip
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } footer: {
                Text("Your account is only used for publishing. Drafts work without an account.")
                    .font(.cucuEditorial(12, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
            }

            if let info = auth.infoMessage {
                Section {
                    Label {
                        Text(info)
                            .font(.cucuEditorial(13, italic: true))
                            .foregroundStyle(Color.cucuInkSoft)
                    } icon: {
                        Image(systemName: "envelope.badge")
                            .foregroundStyle(Color.cucuMoss)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            if let error = auth.errorMessage {
                Section {
                    Label {
                        Text(error)
                            .font(.cucuEditorial(13, italic: true))
                            .foregroundStyle(Color.cucuBurgundy)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.cucuBurgundy)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .cucuFormBackdrop()
    }

    /// Monochrome ink-on-paper submit, paired with the Sign In
    /// chip. Same asymmetric pebble shape so both auth tabs read
    /// as siblings; ✦ flourish kept in paper-tinted form to hold
    /// onto the editorial voice.
    private var submitChip: some View {
        let disabled = email.isEmpty || password.count < 8 || auth.isLoading
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 18,
            bottomTrailingRadius: 28, topTrailingRadius: 28,
            style: .continuous
        )
        return Button {
            auth.clearMessages()
            Task { await auth.signUp(email: email, password: password) }
        } label: {
            HStack(spacing: 9) {
                if auth.isLoading {
                    ProgressView()
                        .tint(Color.cucuPaper)
                        .controlSize(.small)
                } else {
                    Text("Create account")
                        .font(.cucuSerif(15, weight: .semibold))
                        .tracking(0.6)
                    Text("✦")
                        .font(.cucuSerif(13, weight: .regular))
                        .foregroundStyle(Color.cucuPaper.opacity(0.6))
                }
            }
            .foregroundStyle(Color.cucuPaper)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(minWidth: 168)
            .background(shape.fill(Color.cucuInk))
            .overlay(
                shape
                    .inset(by: 3)
                    .strokeBorder(Color.cucuPaper.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.cucuInk.opacity(0.18), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1.0)
    }
}
