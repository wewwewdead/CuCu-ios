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

    /// Moss-variant submit chip for the affirmative action. Shows
    /// the spinner inline so the chip stays put rather than
    /// jumping when the network is in flight.
    private var submitChip: some View {
        let disabled = email.isEmpty || password.isEmpty || auth.isLoading
        return Button {
            auth.clearMessages()
            Task { await auth.signIn(email: email, password: password) }
        } label: {
            HStack(spacing: 6) {
                if auth.isLoading {
                    ProgressView()
                        .tint(Color.cucuMoss)
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Sign In")
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
}
