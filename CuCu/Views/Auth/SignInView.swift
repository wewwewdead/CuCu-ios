import SwiftUI

struct SignInView: View {
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
                SecureField("Password", text: $password)
            }

            Section {
                Button {
                    auth.clearMessages()
                    Task { await auth.signIn(email: email, password: password) }
                } label: {
                    HStack {
                        Spacer()
                        if auth.isLoading {
                            ProgressView()
                        } else {
                            Text("Sign In").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
            }

            if let message = auth.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
    }
}
