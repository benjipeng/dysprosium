import SwiftUI
import UIKit

/// Responsive Safari / Chrome-style Visual Tab Card Grid with live `WKWebView` page thumbnails,
/// multi-profile + orthogonal `Private` scope switching, even column counts (`2` / `4`) across postures,
/// and a floating Liquid Glass bottom action bar.
/// Strictly obeys Liquid Glass layering: cards use pure semantic surfaces (`secondarySystemGroupedBackground`),
/// while `.glassEffect()` is confined exclusively to the floating bottom bar.
struct BrowserTabsSheet: View {
    private enum TabScope: Hashable {
        case profile(String)
        case privateBrowsing

        var isPrivate: Bool {
            if case .privateBrowsing = self { return true }
            return false
        }

        var profileID: String? {
            if case .profile(let id) = self { return id }
            return nil
        }
    }

    @Environment(\.dysprosiumTokens) private var tokens
    @Environment(\.dismiss) private var dismiss
    @Bindable var browserStore: CleanroomBrowserStore

    @State private var selectedScope: TabScope = .profile(BrowserProfile.defaultID)
    @State private var lastSelectedProfileID: String = BrowserProfile.defaultID
    @State private var gridWidth: CGFloat = 460
    @State private var isConfirmingCloseAll: Bool = false
    @State private var isShowingProfilesSheet: Bool = false
    @State private var isShowingNewProfileSheet: Bool = false
    @Namespace private var glassScopeNamespace

    private var selectedProfile: BrowserProfile {
        let lookupID = selectedScope.profileID ?? lastSelectedProfileID
        return browserStore.profile(for: lookupID) ?? browserStore.activeProfile
    }

    private var selectedProfileTabs: [CleanroomWebKitSession] {
        browserStore.tabs(forProfileID: selectedProfile.id)
    }

    private var privateTabs: [CleanroomWebKitSession] {
        browserStore.privateTabs
    }

    private var visibleTabs: [CleanroomWebKitSession] {
        selectedScope.isPrivate ? privateTabs : selectedProfileTabs
    }

    private var activeScopeTokens: DysprosiumTokens {
        selectedProfile.tokens
    }

    private var sheetTitle: String {
        if selectedScope.isPrivate {
            return L("Private Tabs")
        }
        if browserStore.isMultiProfileEnabled {
            let count = visibleTabs.count
            return L("\(selectedProfile.localizedDisplayName) · \(count) Tabs")
        }
        return L("Tabs")
    }

    /// Ordered carousel scopes `[Profile 1 ... K, Private]` for fluid horizontal swipe previews.
    private var orderedScopes: [TabScope] {
        browserStore.profiles.map { .profile($0.id) } + [.privateBrowsing]
    }

    private func selectScope(_ scope: TabScope) {
        withAnimation(.spring(duration: 0.25, bounce: 0.08)) {
            selectedScope = scope
            if let pid = scope.profileID {
                lastSelectedProfileID = pid
            }
        }
    }

    private func cycleScope(delta: Int) {
        let scopes = orderedScopes
        guard scopes.count > 1, let idx = scopes.firstIndex(of: selectedScope) else { return }
        let nextIdx = ((idx + delta) % scopes.count + scopes.count) % scopes.count
        selectScope(scopes[nextIdx])
    }

    /// Strict iPhone Duo even-column rule (`2` or `4`):
    /// - Outer Portrait (`466 pt`), 50/50 Split (`469 pt`), Book Pose half-sheet (`~430 pt`) -> `2` columns (`~185–213 pt`)
    /// - Inner Portrait (`~620–669 pt`) & Inner Landscape `.page` sheet (`~704–760 pt`) -> `4` columns (`~140–174 pt`)
    private var columnCount: Int {
        gridWidth >= 580 ? 4 : 2
    }

    private var isFourColumn: Bool {
        columnCount == 4
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount)
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleTabs.isEmpty && selectedScope.isPrivate {
                    privateEmptyState
                } else if visibleTabs.isEmpty {
                    profileEmptyState
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            if !selectedScope.isPrivate,
                               !browserStore.recentlyClosedTabs(forProfileID: selectedProfile.id).isEmpty {
                                reopenClosedBanner(forProfileID: selectedProfile.id)
                            }

                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(visibleTabs) { tab in
                                    TabPreviewCardView(
                                        tab: tab,
                                        profileAccent: activeScopeTokens.accent,
                                        profileOnAccent: activeScopeTokens.onAccent,
                                        isActive: tab.id == browserStore.activeTabID,
                                        isFourColumn: isFourColumn,
                                        pdfAppearanceMode: browserStore.pdfAppearanceMode,
                                        canCloseOthers: visibleTabs.count > 1,
                                        onSelect: {
                                            browserStore.switchToTab(id: tab.id)
                                            dismiss()
                                        },
                                        onDuplicate: {
                                            withAnimation(.spring(duration: 0.26, bounce: 0.06)) {
                                                browserStore.duplicateTab(id: tab.id)
                                            }
                                        },
                                        onCloseOthers: {
                                            withAnimation(.spring(duration: 0.26, bounce: 0.06)) {
                                                browserStore.closeOtherTabs(keeping: tab.id)
                                            }
                                        },
                                        onClose: {
                                            withAnimation(.spring(duration: 0.26, bounce: 0.06)) {
                                                browserStore.closeTab(id: tab.id)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 18)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .simultaneousGesture(
                DragGesture(minimumDistance: 36, coordinateSpace: .local)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) >= 56, abs(dx) > abs(dy) * 1.5 else { return }
                        cycleScope(delta: dx < 0 ? 1 : -1)
                    }
            )
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.width
            } action: { newWidth in
                gridWidth = newWidth
            }
            .safeAreaInset(edge: .bottom) {
                bottomGlassActionBar
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if browserStore.isMultiProfileEnabled {
                        Button {
                            isShowingProfilesSheet = true
                        } label: {
                            Label(L("Profiles"), systemImage: "person.2")
                                .symbolRenderingMode(.monochrome)
                        }
                        .accessibilityIdentifier("tabs-manage-profiles-button")
                    } else {
                        Button {
                            isShowingNewProfileSheet = true
                        } label: {
                            Label(L("New Profile"), systemImage: "person.crop.circle.badge.plus")
                                .symbolRenderingMode(.monochrome)
                        }
                        .accessibilityIdentifier("tabs-new-profile-button")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let targetPID = selectedScope.profileID {
                            if targetPID != browserStore.activeProfileID || browserStore.activeSession.isPrivate {
                                browserStore.switchToProfile(id: targetPID, activateTab: true)
                            }
                        } else if selectedScope.isPrivate,
                                  !browserStore.activeSession.isPrivate,
                                  let lastPrivate = privateTabs.last {
                            browserStore.switchToTab(id: lastPrivate.id)
                        }
                        dismiss()
                    } label: {
                        Label(L("Done"), systemImage: "checkmark")
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selectedScope)
            .onAppear {
                lastSelectedProfileID = browserStore.activeProfileID
                selectedScope = browserStore.activeSession.isPrivate
                    ? .privateBrowsing
                    : .profile(browserStore.activeProfileID)
                browserStore.prepareTabSwitcherPreviews()
            }
            .onChange(of: browserStore.profiles) { _, updatedProfiles in
                if let pid = selectedScope.profileID,
                   !updatedProfiles.contains(where: { $0.id == pid }) {
                    lastSelectedProfileID = browserStore.activeProfileID
                    selectedScope = .profile(browserStore.activeProfileID)
                }
            }
            .sheet(isPresented: $isShowingProfilesSheet) {
                ProfileManagementSheet(browserStore: browserStore)
            }
            .sheet(isPresented: $isShowingNewProfileSheet) {
                ProfileCreationSheet(browserStore: browserStore) { created in
                    lastSelectedProfileID = created.id
                    selectedScope = .profile(created.id)
                }
            }
            .confirmationDialog(
                selectedScope.isPrivate
                    ? L("Close All \(visibleTabs.count) Private Tabs?")
                    : (browserStore.isMultiProfileEnabled
                        ? L("Close All \(visibleTabs.count) Tabs in \(selectedProfile.localizedDisplayName)?")
                        : L("Close All \(visibleTabs.count) Tabs?")),
                isPresented: $isConfirmingCloseAll,
                titleVisibility: .visible
            ) {
                Button(
                    selectedScope.isPrivate
                        ? L("Close \(visibleTabs.count) Private Tabs")
                        : L("Close \(visibleTabs.count) Tabs"),
                    role: .destructive
                ) {
                    withAnimation(.spring(duration: 0.28, bounce: 0.06)) {
                        browserStore.closeAllTabs(
                            isPrivate: selectedScope.isPrivate,
                            profileID: selectedScope.profileID
                        )
                    }
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                if selectedScope.isPrivate {
                    Text(L("Private tabs and their ephemeral session data will be discarded."))
                } else {
                    Text(L("Closed tabs can be reopened from Recently Closed."))
                }
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var profileEmptyState: some View {
        let p = selectedProfile
        let pTokens = p.tokens
        return VStack(spacing: 14) {
            Spacer()

            ZStack {
                Circle()
                    .fill(pTokens.accentSubtleFill)
                    .frame(width: 60, height: 60)
                Image(systemName: p.symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(pTokens.accent)
            }

            Text(p.localizedDisplayName)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(L("No open tabs in \(p.localizedDisplayName). Cookies, logins, history, and favorites are isolated from other profiles."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                browserStore.openNewTab(isPrivate: false, activate: true, profileID: p.id)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .symbolRenderingMode(.monochrome)
                    Text(L("New Tab in \(p.localizedDisplayName)"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pTokens.onAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .tint(pTokens.accent)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var privateEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                Circle()
                    .fill(tokens.privateAccent.opacity(0.14))
                    .frame(width: 60, height: 60)
                Image(systemName: "hand.raised.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tokens.privateAccent)
            }

            Text(L("Private Browsing"))
                .font(.headline)
                .foregroundStyle(.primary)

            Text(L("Private tabs use an isolated in-memory store and leave zero history, cookies, or cached data once closed."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                browserStore.openNewTab(isPrivate: true, activate: true)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .symbolRenderingMode(.monochrome)
                    Text(L("New Private Tab"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tokens.onPrivateAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .tint(tokens.privateAccent)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var bottomGlassActionBar: some View {
        let isCompactWidth = gridWidth < 430
        let profile = selectedProfile
        let profileTokens = profile.tokens
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: isCompactWidth ? 8 : 10) {
                if visibleTabs.count >= 2 {
                    Button(role: .destructive) {
                        isConfirmingCloseAll = true
                    } label: {
                        if isCompactWidth {
                            Label(L("Close All"), systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 22, height: 22)
                        } else {
                            Text(L("Close All"))
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(isCompactWidth ? .circle : .capsule)
                    .accessibilityLabel(L("Close All"))
                    .accessibilityIdentifier("tabs-close-all-button")
                } else {
                    Color.clear
                        .frame(width: 40, height: 40)
                        .allowsHitTesting(false)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    profileScopeSegment(
                        profile: profile,
                        profileTokens: profileTokens,
                        isCompactWidth: isCompactWidth
                    )
                    privateScopeSegment(isCompactWidth: isCompactWidth)
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: Capsule())

                Spacer(minLength: 4)

                Button {
                    browserStore.openNewTab(
                        isPrivate: selectedScope.isPrivate,
                        activate: true,
                        profileID: selectedScope.isPrivate ? nil : profile.id
                    )
                    dismiss()
                } label: {
                    Label(
                        selectedScope.isPrivate ? L("New Private Tab") : L("New Tab"),
                        systemImage: "plus"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 24, height: 24)
                }
                .tint(selectedScope.isPrivate ? tokens.privateAccent : profileTokens.accent)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("tabs-new-tab-button")
            }
            .padding(.horizontal, isCompactWidth ? 12 : 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func profileScopeSegment(
        profile: BrowserProfile,
        profileTokens: DysprosiumTokens,
        isCompactWidth: Bool
    ) -> some View {
        let isSelected = !selectedScope.isPrivate
        let tabCount = selectedProfileTabs.count

        if !browserStore.isMultiProfileEnabled {
            Button {
                selectScope(.profile(profile.id))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.on.square")
                        .symbolRenderingMode(.monochrome)
                        .font(.caption.weight(.semibold))
                    Text(L("\(tabCount) Tabs"))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(isSelected ? profileTokens.onAccent : .primary)
                .padding(.horizontal, isCompactWidth ? 10 : 12)
                .padding(.vertical, 8.5)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(profileTokens.accent)
                            .matchedGeometryEffect(id: "active-tab-scope", in: glassScopeNamespace)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("\(tabCount) tabs"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("tabs-scope-standard")
        } else if isSelected {
            Menu {
                ProfileSwitcherMenuContent(
                    browserStore: browserStore,
                    selectedProfileID: profile.id,
                    onSelectProfile: { nextID in
                        selectScope(.profile(nextID))
                    },
                    onNewProfile: {
                        isShowingNewProfileSheet = true
                    },
                    onManageProfiles: {
                        isShowingProfilesSheet = true
                    }
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: profile.symbolName)
                        .symbolRenderingMode(.monochrome)
                        .font(.caption.weight(.semibold))
                    Text(profile.localizedDisplayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Text("· \(tabCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(profileTokens.onAccent)
                .padding(.horizontal, isCompactWidth ? 9 : 12)
                .padding(.vertical, 8.5)
                .background {
                    Capsule()
                        .fill(profileTokens.accent)
                        .matchedGeometryEffect(id: "active-tab-scope", in: glassScopeNamespace)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("\(profile.localizedDisplayName), \(tabCount) tabs"))
            .accessibilityHint(L("Switch profile"))
            .accessibilityAddTraits(.isSelected)
            .accessibilityIdentifier("tabs-scope-profile-menu")
        } else {
            Button {
                selectScope(.profile(profile.id))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: profile.symbolName)
                        .symbolRenderingMode(.monochrome)
                        .font(.caption.weight(.semibold))
                    Text(profile.localizedDisplayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Text("· \(tabCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, isCompactWidth ? 9 : 12)
                .padding(.vertical, 8.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("\(profile.localizedDisplayName), \(tabCount) tabs"))
            .accessibilityIdentifier("tabs-scope-profile-button")
        }
    }

    private func privateScopeSegment(isCompactWidth: Bool) -> some View {
        let isSelected = selectedScope.isPrivate
        let count = privateTabs.count
        let title: String
        if count == 0 {
            title = L("Private")
        } else if isCompactWidth && browserStore.isMultiProfileEnabled {
            title = L("Private · \(count)")
        } else {
            title = L("Private (\(count))")
        }
        return Button {
            selectScope(.privateBrowsing)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSelected ? tokens.onPrivateAccent : .primary)
            .padding(.horizontal, isCompactWidth ? 9 : 12)
            .padding(.vertical, 8.5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(tokens.privateAccent)
                        .matchedGeometryEffect(id: "active-tab-scope", in: glassScopeNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 0 ? L("Private") : L("Private, \(count) tabs"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tabs-scope-private")
    }

    @ViewBuilder
    private func reopenClosedBanner(forProfileID profileID: String) -> some View {
        let closedStack = browserStore.recentlyClosedTabs(forProfileID: profileID)
        if let latest = closedStack.first {
            HStack(spacing: 8) {
                Button {
                    _ = browserStore.reopenLastClosedTab(profileID: profileID)
                    dismiss()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.uturn.backward")
                            .symbolRenderingMode(.monochrome)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(activeScopeTokens.accent)

                        Text(L("Reopen Closed"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text("· \(latest.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Reopen Closed"))
                .accessibilityIdentifier("tabs-reopen-closed-button")

                Spacer(minLength: 4)

                if closedStack.count > 1 {
                    Menu {
                        ForEach(closedStack) { entry in
                            Button {
                                browserStore.openNewTab(
                                    urlString: entry.urlString,
                                    isPrivate: false,
                                    activate: true,
                                    profileID: profileID
                                )
                                dismiss()
                            } label: {
                                Label(entry.title, systemImage: "globe")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            browserStore.clearRecentlyClosedTabs(profileID: profileID)
                        } label: {
                            Label(L("Clear Recently Closed"), systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(closedStack.count)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                            Image(systemName: "chevron.down")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .accessibilityLabel(L("Recently Closed Tabs List"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Individual Tab Preview Card (Chrome + Safari iOS 27 Concentric Card Architecture)

private struct TabPreviewCardView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    let tab: CleanroomWebKitSession
    let profileAccent: Color
    let profileOnAccent: Color
    let isActive: Bool
    let isFourColumn: Bool
    let pdfAppearanceMode: PDFAppearanceMode
    let canCloseOthers: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onCloseOthers: () -> Void
    let onClose: () -> Void

    private var activeTint: Color {
        tab.isPrivate ? tokens.privateAccent : profileAccent
    }

    private var activeOnTint: Color {
        tab.isPrivate ? tokens.onPrivateAccent : profileOnAccent
    }

    private var isStartPage: Bool {
        tab.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tab.activePDF == nil
    }

    private var isPDFTab: Bool {
        tab.isViewingPDF || tab.isLoadingInlinePDF
    }

    private var viewportCanvasColor: Color {
        if isStartPage {
            return Color(.systemGroupedBackground)
        }
        if tab.activePDF != nil {
            return Color(uiColor: pdfAppearanceMode.canvasUIColor)
        }
        if let sampled = tab.pageCanvasColor {
            return Color(uiColor: sampled)
        }
        return Color(.systemBackground)
    }

    var body: some View {
        let iconSize: CGFloat = isFourColumn ? 14 : 15
        let viewportRatio: CGFloat = isFourColumn ? 1.08 : 1.0

        VStack(spacing: 0) {
            // Compact Card Header: Site/PDF Icon + 1-line Title + 18 pt Visual Close Pill (`28 pt` Touch Target)
            HStack(spacing: 5) {
                if tab.isPrivate && isStartPage {
                    Image(systemName: "hand.raised.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? activeTint : .secondary)
                        .frame(width: iconSize, height: iconSize)
                } else if isPDFTab {
                    Image(systemName: "doc.richtext.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: isFourColumn ? 11.5 : 12.5, weight: .semibold))
                        .foregroundStyle(isActive ? activeTint : .secondary)
                        .frame(width: iconSize, height: iconSize)
                } else if tab.isPrivate {
                    Image(systemName: "hand.raised.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? activeTint : .secondary)
                        .frame(width: iconSize, height: iconSize)
                } else if isStartPage {
                    Image(systemName: "square.grid.2x2")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? activeTint : .secondary)
                        .frame(width: iconSize, height: iconSize)
                } else {
                    SiteIconView(
                        urlString: tab.currentURLString,
                        title: tab.displayTabTitle,
                        size: iconSize
                    )
                }

                Text(tab.displayTabTitle)
                    .font(.system(size: isFourColumn ? 11.5 : 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color(.tertiarySystemFill), in: Circle())
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close \(tab.displayTabTitle)"))
            }
            .padding(.leading, 8)
            .padding(.trailing, 3)
            .padding(.vertical, 2)

            // Concentric Preview Viewport (`15 pt` outer - `4 pt` inset = `11 pt` inner radius)
            Button(action: onSelect) {
                viewportCanvasColor
                    .aspectRatio(viewportRatio, contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            if isStartPage {
                                startPageMiniature
                                    .frame(width: geo.size.width, height: geo.size.height)
                            } else if let snapshot = tab.previewSnapshot {
                                Image(uiImage: snapshot)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                                    .clipped()
                            } else {
                                unhydratedPagePlaceholder
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        previewFooterBadges
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: .black.opacity(isActive ? 0.10 : 0.04),
                    radius: isActive ? 7 : 2.5,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    isActive ? activeTint : .primary.opacity(0.09),
                    lineWidth: isActive ? 2.2 : 0.6
                )
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button(action: onDuplicate) {
                Label(L("Duplicate Tab"), systemImage: "plus.square.on.square")
            }

            if canCloseOthers {
                Button(action: onCloseOthers) {
                    Label(L("Close Other Tabs"), systemImage: "xmark.square")
                }
            }

            Divider()

            Button(role: .destructive, action: onClose) {
                Label(L("Close Tab"), systemImage: "xmark")
            }
        }
    }

    private var startPageMiniature: some View {
        VStack(spacing: 6) {
            Image("ElementEmblem")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: isFourColumn ? 28 : 34, height: isFourColumn ? 28 : 34)
                .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                }

            Text(tab.isPrivate ? L("Private Start") : L("Start Page"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var unhydratedPagePlaceholder: some View {
        VStack(spacing: 6) {
            if isPDFTab {
                Image(systemName: "doc.richtext.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: isFourColumn ? 22 : 26, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                SiteIconView(
                    urlString: tab.currentURLString,
                    title: tab.displayTabTitle,
                    size: isFourColumn ? 26 : 32
                )
            }

            Text(tab.displayHost)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(viewportCanvasColor)
    }

    @ViewBuilder
    private var previewFooterBadges: some View {
        HStack(spacing: 4) {
            if let pdf = tab.activePDF {
                Text(pdf.pageCount > 0 ? L("PDF · \(pdf.pageCount)p") : L("PDF"))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .background(Color(.systemBackground).opacity(0.84), in: Capsule())
            } else if !isStartPage {
                Text(tab.displayHost)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .background(Color(.systemBackground).opacity(0.84), in: Capsule())
            }

            Spacer(minLength: 0)

            if !tab.mediaGroups.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 8.5, weight: .bold))
                    Text("\(tab.mediaGroups.count)")
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(activeOnTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(activeTint, in: Capsule())
            }
        }
        .padding(6)
    }
}
