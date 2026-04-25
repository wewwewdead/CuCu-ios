import SwiftUI

/// Picker over the system-safe font families. Each option renders in its own
/// design so users can preview the difference without committing.
struct FontPickerView: View {
    let label: String
    @Binding var selection: ProfileFontName

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(ProfileFontName.allCases, id: \.self) { name in
                Text(name.rawValue)
                    .font(.system(.body, design: name.design))
                    .tag(name)
            }
        }
    }
}
