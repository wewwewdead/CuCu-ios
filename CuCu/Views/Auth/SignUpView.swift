import SwiftUI

struct SignUpView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("Email") {
                TextField("you@example.com", text: $email)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .autocorrectionDisabled()
            }
            Section("Password") {
                SecureField("At least 8 characters", text: $password)
            }

            Section {
                Button {
                    auth.clearMessages()
                    Task { await auth.signUp(email: email, password: password) }
                } label: {
                    HStack {
                        Spacer()
                        if auth.isLoading {
                            ProgressView()
                        } else {
                            Text("Create account").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(email.isEmpty || password.count < 8 || auth.isLoading)
            } footer: {
                Text("Your account is only used for publishing. Drafts work without an account.")
            }

            if let info = auth.infoMessage {
                Section {
                    Label(info, systemImage: "envelope.badge")
                        .foregroundStyle(.blue)
                        .font(.footnote)
                }
            }
            if let error = auth.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
    }
}
