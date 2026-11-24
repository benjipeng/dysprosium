import SwiftUI

/// Single reusable native SwiftUI `Menu` content for switching, creating, and managing browser profiles.
///
/// Uses an inline `Picker` so iOS natively displays the selection checkmark alongside each profile's
/// SF Symbol rather than replacing the symbol, ensuring consistent behavior across the omnibox chip,
/// More menu, Start Page switcher, and Tabs overview pill.
struct ProfileSwitcherMenuContent: View {
    let browserStore: CleanroomBrowserStore
    let selectedProfileID: String
    let onSelectProfile: (String) -> Void
    let onNewProfile: (() -> Void)?
    let onManageProfiles: (() -> Void)?

    init(
        browserStore: CleanroomBrowserStore,
        selectedProfileID: String? = nil,
        onSelectProfile: ((String) -> Void)? = nil,
        onNewProfile: (() -> Void)? = nil,
        onManageProfiles: (() -> Void)? = nil
    ) {
        self.browserStore = browserStore
        self.selectedProfileID = selectedProfileID ?? browserStore.activeProfileID
        self.onSelectProfile = onSelectProfile ?? { id in
            browserStore.switchToProfile(id: id, activateTab: true)
        }
        self.onNewProfile = onNewProfile
        self.onManageProfiles = onManageProfiles
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { selectedProfileID },
            set: { nextID in
                onSelectProfile(nextID)
            }
        )
    }

    var body: some View {
        Picker(L("Profile"), selection: selectionBinding) {
            ForEach(browserStore.profiles) { profile in
                let count = browserStore.tabs(forProfileID: profile.id).count
                Label(L("\(profile.localizedDisplayName) (\(count))"), systemImage: profile.symbolName)
                    .tag(profile.id)
            }
        }
        .pickerStyle(.inline)

        if onNewProfile != nil || onManageProfiles != nil {
            Divider()

            if let onNewProfile, browserStore.profiles.count < BrowserProfile.maxProfileCount {
                Button(action: onNewProfile) {
                    Label(L("New Profile…"), systemImage: "person.crop.circle.badge.plus")
                }
            }

            if let onManageProfiles {
                Button(action: onManageProfiles) {
                    Label(L("Manage Profiles…"), systemImage: "person.2")
                }
            }
        }
    }
}
