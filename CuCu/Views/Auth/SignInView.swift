import SwiftUI

struct SignInView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        formBody
            .onChange(of: auth.isSignedIn) { wasIn, nowIn in
                if !wasIn && nowIn {
                    CucuHaptics.success()
                }
            }
    }

    private var formBody: some View {
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
                SecureField("Password", text: $password)
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
            }

            if let message = auth.errorMessage {
                Section {
                    Label {
                        Text(message)
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

    /// Monochrome ink-on-paper submit. Asymmetric pebble shape
    /// (small radius leading, half-round trailing) leans toward
    /// the action; paper hairline inset 3pt keeps the letterpress
    /// detail in voice.
    private var submitChip: some View {
        let disabled = email.isEmpty || password.isEmpty || auth.isLoading
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 18,
            bottomTrailingRadius: 28, topTrailingRadius: 28,
            style: .continuous
        )
        return Button {
            auth.clearMessages()
            Task { await auth.signIn(email: email, password: password) }
        } label: {
            HStack(spacing: 9) {
                if auth.isLoading {
                    ProgressView()
                        .tint(Color.cucuPaper)
                        .controlSize(.small)
                } else {
                    Text("Sign In")
                        .font(.cucuSerif(15, weight: .semibold))
                        .tracking(0.6)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.cucuPaper)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(minWidth: 132)
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
