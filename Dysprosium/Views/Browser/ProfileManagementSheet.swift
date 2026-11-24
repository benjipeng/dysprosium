import SwiftUI

/// Native `.insetGrouped` sheet listing all persistent browser profiles (`1...6`),
/// allowing 1-tap switching, creation, editing, seed rotation, profile-scoped clearing, and safe deletion.
struct ProfileManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var browserStore: CleanroomBrowserStore

    @State private var isShowingCreateSheet: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browserStore.profiles) { profile in
                        let isActive = (profile.id == browserStore.activeProfileID)
                        let tabCount = browserStore.tabs(forProfileID: profile.id).count
                        let favCount = browserStore.bookmarkCount(forProfileID: profile.id)
                        let profileTokens = profile.tokens

                        NavigationLink {
                            ProfileEditorView(
                                browserStore: browserStore,
                                profile: profile,
                                onSwitched: { dismiss() },
                                onDeleted: {}
                            )
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(profileTokens.accentSubtleFill)
                                        .frame(width: 36, height: 36)
                                    Image(systemName: profile.symbolName)
                                        .symbolRenderingMode(.monochrome)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(profileTokens.accent)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(profile.localizedDisplayName)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if isActive {
                                            Text(L("profile.status.active"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(profileTokens.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(profileTokens.accentSubtleFill, in: Capsule())
                                        }
                                    }

                                    let tabSummary = L("\(tabCount) tabs")
                                    let favSummary = L("\(favCount) favorites")
                                    Text(L("\(tabSummary) · \(favSummary) · \(profile.userAgentProfile.shortLabel)"))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)
                            }
                            .padding(.vertical, 2)
                        }
                        .accessibilityIdentifier("profile-row-\(profile.name.lowercased())")
                        .accessibilityAction(named: isActive ? L("Edit \(profile.localizedDisplayName)") : L("Switch to \(profile.localizedDisplayName)")) {
                            if !isActive {
                                browserStore.switchToProfile(id: profile.id, activateTab: true)
                                dismiss()
                            }
                        }
                        .contextMenu {
                            if !isActive {
                                Button {
                                    browserStore.switchToProfile(id: profile.id, activateTab: true)
                                    dismiss()
                                } label: {
                                    Label(L("Switch to \"\(profile.localizedDisplayName)\""), systemImage: "arrow.left.arrow.right")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !isActive {
                                Button {
                                    browserStore.switchToProfile(id: profile.id, activateTab: true)
                                    dismiss()
                                } label: {
                                    Label(L("Switch"), systemImage: "arrow.left.arrow.right")
                                }
                                .tint(profileTokens.accent)
                            }
                        }
                    }
                } header: {
                    Text(L("Profiles (\(browserStore.profiles.count)/\(BrowserProfile.maxProfileCount))"))
                } footer: {
                    Text(L("Each profile isolates cookies, logins, open tabs, history, favorites, per-site rules, and its own 256-bit fingerprint seed. Downloads Vault and Private Browsing stay unified."))
                }

                if browserStore.profiles.count < BrowserProfile.maxProfileCount {
                    Section {
                        Button {
                            isShowingCreateSheet = true
                        } label: {
                            Label(L("New Profile…"), systemImage: "plus.circle.fill")
                                .symbolRenderingMode(.monochrome)
                                .font(.body.weight(.medium))
                        }
                        .accessibilityIdentifier("profiles-create-new-button")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
            .navigationTitle(L("Profiles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(L("Done"), systemImage: "checkmark")
                    }
                }
            }
            .sheet(isPresented: $isShowingCreateSheet) {
                ProfileCreationSheet(browserStore: browserStore) { _ in
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Focused <10-second creation sheet for adding a new isolated browser profile.
struct ProfileCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var browserStore: CleanroomBrowserStore
    var onCreated: ((BrowserProfile) -> Void)? = nil

    @State private var name: String = ""
    @State private var selectedSymbol: String
    @State private var selectedPalette: DysprosiumPalettePreset
    @State private var selectedUA: BrowserUserAgentProfile = .iosSafari
    @State private var selectedSearchEngine: BrowserSearchEngine = .duckDuckGo
    @State private var customSearchTemplate: String = BrowserSearchEngine.defaultCustomTemplate
    @State private var copyFavoritesFromDefault: Bool = false

    init(
        browserStore: CleanroomBrowserStore,
        onCreated: ((BrowserProfile) -> Void)? = nil
    ) {
        self.browserStore = browserStore
        self.onCreated = onCreated
        let usedPalettes = Set(browserStore.profiles.map(\.palettePreset))
        let usedSymbols = Set(browserStore.profiles.map(\.symbolName))
        let firstUnusedSuggestion = BrowserProfile.quickNameSuggestions.first { suggestion in
            !browserStore.profiles.contains { $0.name.caseInsensitiveCompare(suggestion.name) == .orderedSame }
        }
        let defaultNextPalette = firstUnusedSuggestion?.palette
            ?? DysprosiumPalettePreset.allCases.first(where: { !usedPalettes.contains($0) })
            ?? .ultramarine
        let defaultNextSymbol = firstUnusedSuggestion?.symbol
            ?? BrowserProfile.curatedSymbols.first(where: { !usedSymbols.contains($0.symbol) })?.symbol
            ?? "briefcase.fill"
        _selectedPalette = State(initialValue: defaultNextPalette)
        _selectedSymbol = State(initialValue: defaultNextSymbol)
    }

    private var previewTokens: DysprosiumTokens {
        DysprosiumTokens(preset: selectedPalette)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && browserStore.profiles.count < BrowserProfile.maxProfileCount
    }

    private var availableSuggestions: [(name: String, symbol: String, palette: DysprosiumPalettePreset)] {
        BrowserProfile.quickNameSuggestions.filter { suggestion in
            !browserStore.profiles.contains { $0.name.caseInsensitiveCompare(suggestion.name) == .orderedSame }
        }
    }

    private static func quickChipIdentifierSlug(forSymbol symbol: String, fallbackName: String) -> String {
        switch symbol {
        case "briefcase.fill": return "work"
        case "graduationcap.fill": return "study"
        case "flask.fill": return "research"
        case "play.rectangle.fill": return "media"
        default: return fallbackName.lowercased()
        }
    }

    var body: some View {
        let defaultName = browserStore.profiles.first(where: \.isDefault)?.localizedDisplayName ?? L("Personal")
        let defaultFavCount = browserStore.bookmarkCount(forProfileID: BrowserProfile.defaultID)
        NavigationStack {
            List {
                // 1. Live Identity Header + Name + Quick Chips
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(previewTokens.accentSubtleFill)
                                .frame(width: 44, height: 44)
                            Image(systemName: selectedSymbol)
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(previewTokens.accent)
                        }

                        TextField(L("Profile Name (e.g. Work)"), text: $name)
                            .font(.body.weight(.medium))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("profile-create-name-field")
                            .onChange(of: name) { _, updated in
                                if updated.count > BrowserProfile.maxNameLength {
                                    name = String(updated.prefix(BrowserProfile.maxNameLength))
                                }
                            }

                        if name.count >= 14 {
                            Text("\(name.count)/\(BrowserProfile.maxNameLength)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(name.count >= BrowserProfile.maxNameLength ? previewTokens.accent : .secondary)
                                .fixedSize()
                        }
                    }
                    .padding(.vertical, 2)

                    if !availableSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(availableSuggestions, id: \.symbol) { suggestion in
                                    Button {
                                        withAnimation(.snappy(duration: 0.2)) {
                                            name = suggestion.name
                                            selectedSymbol = suggestion.symbol
                                            selectedPalette = suggestion.palette
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: suggestion.symbol)
                                                .symbolRenderingMode(.monochrome)
                                                .font(.caption.weight(.semibold))
                                            Text(suggestion.name)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(DysprosiumTokens(preset: suggestion.palette).accent)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(DysprosiumTokens(preset: suggestion.palette).accentSubtleFill, in: Capsule())
                                        .frame(minHeight: 40)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("profile-quick-chip-\(Self.quickChipIdentifierSlug(forSymbol: suggestion.symbol, fallbackName: suggestion.name))")
                                }
                            }
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                } header: {
                    Text(L("Name"))
                } footer: {
                    if browserStore.profiles.count == 1 {
                        Text(L("Your existing tabs, bookmarks, and history stay in \"\(browserStore.activeProfile.localizedDisplayName)\"."))
                    }
                }

                // 2. Icon & Lanthanide Accent Palette
                Section(L("Appearance")) {
                    ProfileSymbolPickerGrid(
                        selectedSymbol: $selectedSymbol,
                        accentColor: previewTokens.accent,
                        subtleFill: previewTokens.accentSubtleFill
                    )

                    DysprosiumPaletteSelectorRows(
                        selectedPreset: selectedPalette,
                        title: L("Accent"),
                        onSelect: { selectedPalette = $0 }
                    )
                }

                // 3. Favorites Bootstrap (shown only when Default Profile actually has favorites)
                if defaultFavCount > 0 {
                    Section {
                        Toggle(L("Copy Favorites from \(defaultName) (\(defaultFavCount))"), isOn: $copyFavoritesFromDefault)
                            .font(.subheadline)
                            .accessibilityIdentifier("profile-copy-favorites-toggle")
                    } header: {
                        Text(L("Favorites"))
                    } footer: {
                        Text(L("Leave off to start with a clean favorites grid for this profile."))
                    }
                }

                // 4. Identity & Search Defaults
                Section {
                    Picker(L("Search Engine"), selection: $selectedSearchEngine) {
                        ForEach(BrowserSearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }

                    if selectedSearchEngine == .custom {
                        TextField("https://example.com/search?q=%s", text: $customSearchTemplate)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.subheadline.monospaced())
                    }

                    Picker(L("User-Agent"), selection: $selectedUA) {
                        ForEach(BrowserUserAgentProfile.allCases) { ua in
                            Text(ua.title).tag(ua)
                        }
                    }
                } header: {
                    Text(L("Defaults"))
                } footer: {
                    Text(L("A unique 256-bit anti-fingerprinting seed and isolated WebKit cookie store are created automatically."))
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
            .navigationTitle(L("New Profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(L("Cancel"), systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let created = browserStore.createProfile(
                            name: name,
                            symbolName: selectedSymbol,
                            palettePreset: selectedPalette,
                            userAgentProfile: selectedUA,
                            searchEngine: selectedSearchEngine,
                            customSearchTemplate: customSearchTemplate,
                            copyFavoritesFromDefault: copyFavoritesFromDefault,
                            activate: true
                        ) {
                            dismiss()
                            onCreated?(created)
                        }
                    } label: {
                        Label(L("Create"), systemImage: "checkmark")
                    }
                    .fontWeight(.semibold)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("profile-create-confirm-button")
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Detail editor for renaming, re-theming, switching into, rotating fingerprint seed, clearing data,
/// or safely deleting an existing browser profile.
struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var browserStore: CleanroomBrowserStore
    let profileID: String
    var onSwitched: () -> Void = {}
    var onDeleted: () -> Void

    @State private var name: String
    @State private var selectedSymbol: String
    @State private var selectedPalette: DysprosiumPalettePreset
    @State private var selectedUA: BrowserUserAgentProfile
    @State private var selectedSearchEngine: BrowserSearchEngine
    @State private var customSearchTemplate: String
    @State private var isShowingClearDataSheet: Bool = false
    @State private var isConfirmingDelete: Bool = false
    @State private var isDeleting: Bool = false

    init(
        browserStore: CleanroomBrowserStore,
        profile: BrowserProfile,
        onSwitched: @escaping () -> Void = {},
        onDeleted: @escaping () -> Void
    ) {
        self.browserStore = browserStore
        self.profileID = profile.id
        self.onSwitched = onSwitched
        self.onDeleted = onDeleted
        _name = State(initialValue: profile.name)
        _selectedSymbol = State(initialValue: profile.symbolName)
        _selectedPalette = State(initialValue: profile.palettePreset)
        _selectedUA = State(initialValue: profile.userAgentProfile)
        _selectedSearchEngine = State(initialValue: profile.searchEngine)
        _customSearchTemplate = State(initialValue: profile.customSearchTemplate)
    }

    private var liveProfile: BrowserProfile {
        browserStore.profile(for: profileID) ?? BrowserProfile.makeDefaultProfile()
    }

    private var previewTokens: DysprosiumTokens {
        DysprosiumTokens(preset: selectedPalette)
    }

    private var isActiveProfile: Bool {
        browserStore.activeProfileID == profileID
    }

    private var isNameBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let current = liveProfile
        let tabCount = browserStore.tabs(forProfileID: profileID).count
        let favCount = browserStore.bookmarkCount(forProfileID: profileID)
        let persona = FingerprintShieldEngine.persona(forSeed: current.fingerprintSeed, profile: selectedUA)

        List {
            if !isActiveProfile {
                Section {
                    Button {
                        commitEdits(debounced: false)
                        browserStore.switchToProfile(id: profileID, activateTab: true)
                        onSwitched()
                    } label: {
                        Label(L("Switch to \"\(current.localizedDisplayName)\""), systemImage: "arrow.left.arrow.right.circle.fill")
                            .symbolRenderingMode(.monochrome)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(previewTokens.accent)
                    }
                    .accessibilityIdentifier("profile-editor-switch-button")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(previewTokens.accentSubtleFill)
                                .frame(width: 40, height: 40)
                            Image(systemName: selectedSymbol)
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(previewTokens.accent)
                        }

                        TextField(L("Profile Name"), text: $name)
                            .font(.body.weight(.medium))
                            .onSubmit {
                                commitEdits(debounced: false)
                            }
                            .onChange(of: name) { _, updated in
                                if updated.count > BrowserProfile.maxNameLength {
                                    name = String(updated.prefix(BrowserProfile.maxNameLength))
                                }
                                if !isNameBlank {
                                    commitEdits(debounced: true)
                                }
                            }

                        if name.count >= 14 {
                            Text("\(name.count)/\(BrowserProfile.maxNameLength)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(name.count >= BrowserProfile.maxNameLength ? previewTokens.accent : .secondary)
                                .fixedSize()
                        }
                    }

                    if isNameBlank {
                        Text(L("Profile name cannot be empty."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)

                ProfileSymbolPickerGrid(
                    selectedSymbol: $selectedSymbol,
                    accentColor: previewTokens.accent,
                    subtleFill: previewTokens.accentSubtleFill
                )
                .onChange(of: selectedSymbol) { _, _ in commitEdits(debounced: false) }

                DysprosiumPaletteSelectorRows(
                    selectedPreset: selectedPalette,
                    title: L("Accent"),
                    onSelect: { preset in
                        selectedPalette = preset
                        commitEdits(debounced: false)
                    }
                )
            } header: {
                Text(L("Identity"))
            }

            Section(L("Browsing Defaults")) {
                Picker(L("Search Engine"), selection: $selectedSearchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .onChange(of: selectedSearchEngine) { _, _ in commitEdits(debounced: false) }

                if selectedSearchEngine == .custom {
                    TextField("https://example.com/search?q=%s", text: $customSearchTemplate)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.subheadline.monospaced())
                        .onSubmit { commitEdits(debounced: false) }
                        .onChange(of: customSearchTemplate) { _, _ in commitEdits(debounced: true) }
                }

                Picker(L("User-Agent"), selection: $selectedUA) {
                    ForEach(BrowserUserAgentProfile.allCases) { ua in
                        Text(ua.title).tag(ua)
                    }
                }
                .onChange(of: selectedUA) { _, _ in commitEdits(debounced: false) }
            }

            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Fingerprint Seed"))
                            .font(.subheadline)
                        Text("\(current.shortSeedSpecimen) · \(persona.shortLabel)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        _ = browserStore.rotateFingerprintSeed(forProfileID: profileID)
                    } label: {
                        Label(L("Rotate"), systemImage: "arrow.trianglehead.2.clockwise")
                            .font(.caption.weight(.semibold))
                            .symbolRenderingMode(.monochrome)
                    }
                    .buttonStyle(.bordered)
                    .tint(previewTokens.accent)
                    .controlSize(.small)
                }

                Button {
                    isShowingClearDataSheet = true
                } label: {
                    Label(L("Website Data & Storage…"), systemImage: "internaldrive")
                        .symbolRenderingMode(.monochrome)
                }
            } header: {
                Text(L("Privacy & Storage"))
            } footer: {
                if current.isDefault {
                    Text(L("The default profile cannot be deleted, but its browsing data and fingerprint seed can be cleared or rotated at any time."))
                }
            }

            if !current.isDefault {
                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isDeleting ? L("Deleting Profile…") : L("Delete \"\(current.localizedDisplayName)\"…"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("profile-editor-delete-button")
                } footer: {
                    let tabSummary = L("\(tabCount) tabs")
                    let favSummary = L("\(favCount) favorites")
                    Text(L("Removes \(tabSummary), \(favSummary), history, and isolated site cookies. Files saved in Downloads Vault are untouched."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .navigationTitle(current.localizedDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            commitEdits(debounced: false)
        }
        .sheet(isPresented: $isShowingClearDataSheet) {
            ClearBrowsingDataSheet(browserStore: browserStore, targetProfileID: profileID)
        }
        .confirmationDialog(
            L("Delete \"\(current.localizedDisplayName)\"?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L("Delete Profile & Site Data"), role: .destructive) {
                isDeleting = true
                Task { @MainActor in
                    await browserStore.deleteProfile(id: profileID)
                    isDeleting = false
                    dismiss()
                    onDeleted()
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            let tabSummary = L("\(tabCount) tabs")
            let favSummary = L("\(favCount) favorites")
            Text(L("Removes \(tabSummary), \(favSummary), browsing history, and isolated site logins for \"\(current.localizedDisplayName)\". Downloads in Vault are kept."))
        }
    }

    private func commitEdits(debounced: Bool) {
        guard var updated = browserStore.profile(for: profileID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            updated.name = BrowserProfile.sanitizedName(trimmed)
        }
        updated.symbolName = selectedSymbol
        updated.palettePreset = selectedPalette
        updated.userAgentProfile = selectedUA
        updated.searchEngine = selectedSearchEngine
        updated.customSearchTemplate = customSearchTemplate
        browserStore.updateProfile(updated, debounced: debounced)
    }
}

private struct ProfileSymbolPickerGrid: View {
    @Binding var selectedSymbol: String
    let accentColor: Color
    let subtleFill: Color

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(BrowserProfile.curatedSymbols) { option in
                let isSelected = (selectedSymbol == option.symbol)
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selectedSymbol = option.symbol
                    }
                } label: {
                    Image(systemName: option.symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? accentColor : .secondary)
                        .frame(width: 40, height: 40)
                        .background(
                            isSelected ? subtleFill : Color(.tertiarySystemFill),
                            in: Circle()
                        )
                        .overlay {
                            Circle()
                                .strokeBorder(isSelected ? accentColor : .clear, lineWidth: 1.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.localizedLabel)
                .accessibilityValue(isSelected ? L("Selected") : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
