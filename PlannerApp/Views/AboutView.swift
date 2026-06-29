import SwiftUI

/// House-style About screen: app card, developer card with link, and version row.
struct AboutView: View {
    private let developerURL = URL(string: "https://www.tertiaryinfotech.com")!

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // App card
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Planner", systemImage: "checklist")
                            .font(.title3.bold())
                        Text("An AI-assisted to-do and planner. Add tasks and appointments by typing or by voice — native speech-to-text plus on-device intelligence sorts them for you. Appointments appear in the built-in calendar, checked items auto-archive, and everything syncs to your personal iCloud.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()

                    // Developer card
                    Text("DEVELOPER")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Tertiary Infotech Academy Pte Ltd", systemImage: "building.2.fill")
                            .padding(.vertical, 14)
                        Divider()
                        Link(destination: developerURL) {
                            Label("tertiaryinfotech.com", systemImage: "globe")
                        }
                        .padding(.vertical, 14)
                    }
                    .padding(.horizontal, 16)
                    .background(Theme.card, in: Theme.cardShape)

                    // Sync card
                    Text("DATA & SYNC")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Label("iCloud sync", systemImage: "icloud.fill")
                        Spacer()
                        Text("Private database").foregroundStyle(.secondary)
                    }
                    .cardSurface()

                    // Version row
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(versionString).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(22)
            }
            .navigationTitle("About")
        }
    }
}

#Preview {
    AboutView()
}

#Preview("Dark") {
    AboutView().preferredColorScheme(.dark)
}
