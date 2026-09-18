import SwiftUI

/// Custom "About NovaCAD" content, replacing the default system-generated
/// About panel (which shows only the app name/version/copyright pulled from
/// Info.plist, with no room for an author credit/project link) — per an
/// explicit request to credit an author and link the project.
///
/// Presented as its own `Window` scene (see `DWGViewerApp.body`) rather than
/// an `NSAlert`/sheet: a real About window is closable independently of any
/// document window, can be left open while the user keeps working (matching
/// every other Mac app's About box), and is the idiomatic SwiftUI mechanism
/// for replacing `CommandGroup(replacing: .appInfo)`'s default action.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            VStack(spacing: 4) {
                Text("NovaCAD")
                    .font(.title2).bold()
                // `AppVersion.current` (not a raw Info.plist read) so this
                // matches the Welcome/What's New screen and the shared
                // `.pkg`'s own filename exactly — see that type's doc comment.
                Text("Version \(AppVersion.current)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Divider().frame(width: 220)
            VStack(spacing: 3) {
                Text("Created by Ryan DiRezze")
                    .font(.callout)
                Link("github.com/ryandirezze", destination: URL(string: "https://github.com/ryandirezze")!)
                    .font(.callout)
                Text("Project on GitHub")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(28)
        .frame(width: 300)
        .fixedSize()
    }
}
