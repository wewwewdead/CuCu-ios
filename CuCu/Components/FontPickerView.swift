import SwiftUI

/// Picker over the system-safe font families. Each option renders in its own
/// design so users can preview the difference without committing.
struct FontPickerView: View {
    let label: String
    @Binding var selection: ProfileFontName

    var body: some View {
        Picker(selection: $selection) {
            ForEach(ProfileFontName.allCases, id: \.self) { name in
                Text(name.rawValue.capitalized)
                    .font(.system(.body, design: name.design))
                    .tag(name)
            }
        } label: {
            Text(label)
                .font(.cucuSerif(15, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
        }
    }
}
