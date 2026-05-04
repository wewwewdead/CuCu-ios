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

    private var submitChip: some View {
        let disabled = email.isEmpty || password.count < 8 || auth.isLoading
        return Button {
            auth.clearMessages()
            Task { await auth.signUp(email: email, password: password) }
        } label: {
            HStack(spacing: 6) {
                if auth.isLoading {
                    ProgressView()
                        .tint(Color.cucuMoss)
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Create account")
                        .font(.cucuSerif(15, weight: .semibold))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minWidth: 140)
            .foregroundStyle(Color.cucuMoss)
            .background(Capsule().fill(Color.cucuMossSoft))
            .overlay(Capsule().strokeBorder(Color.cucuMoss, lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }
}
