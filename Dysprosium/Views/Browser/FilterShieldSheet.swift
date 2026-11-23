import SwiftUI

/// Native `.insetGrouped` Filter Subscription, Anti-Adblock & Privacy Management Sheet
/// rendered over pure system sheet material (`UISheetPresentationController`).
struct FilterShieldManagementSheet: View {
    @Environment(\.dysprosiumTokens) private var tokens
    var session: CleanroomWebKitSession?
    var browserStore: CleanroomBrowserStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var customTitle: String = ""
    @State private var customURL: String = ""
    @State private var customCategory: FilterSubscription.Category = .ads
    private var blocker = CleanroomContentBlocker.shared

    var body: some View {
        NavigationStack {
            List {
                Section("WebKit Content Shield") {
                    if let browserStore {
                        Toggle(
                            "Ad, Popup & Anti-Adblock Shield",
                            isOn: Binding(
                                get: { browserStore.isShieldEnabled },
                                set: { browserStore.isShieldEnabled = $0 }
                            )
                        )
                    } else if let session {
                        Toggle(
                            "Ad, Popup & Anti-Adblock Shield",
                            isOn: Binding(
                                get: { session.isShieldEnabled },
                                set: { session.setShieldEnabled($0) }
                            )
                        )
                    }

                    LabeledContent("Compiled DFA Rules") {
                        if blocker.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(blocker.activeRuleCount.formatted())
                                .font(.subheadline.monospacedDigit())
                        }
                    }

                    if let session {
                        LabeledContent("Popups Blocked", value: "\(session.blockedPopupCount)")
                            .font(.subheadline.monospacedDigit())
                    }

                    LabeledContent("Last Updated") {
                        if let last = blocker.lastGlobalSyncDate {
                            Text(last, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Syncing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await blocker.refreshAllSubscriptions(force: true) }
                    } label: {
                        Label(
                            blocker.isSyncing ? "Updating Filter Lists…" : "Update Filter Lists Now",
                            systemImage: "arrow.clockwise"
                        )
                        .symbolRenderingMode(.monochrome)
                    }
                    .disabled(blocker.isSyncing)
                }

                ForEach(FilterSubscription.Category.allCases, id: \.self) { category in
                    let categorySubs = blocker.subscriptions.filter { $0.category == category }
                    if !categorySubs.isEmpty {
                        Section {
                            ForEach(categorySubs) { sub in
                                Toggle(
                                    isOn: Binding(
                                        get: { sub.isEnabled },
                                        set: { _ in
                                            Task { await blocker.toggleSubscription(id: sub.id) }
                                        }
                                    )
                                ) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sub.title)
                                            .font(.subheadline)
                                        HStack(spacing: 6) {
                                            Text(sub.subtitle)
                                                .lineLimit(1)
                                            if let err = sub.lastError {
                                                Text("· \(err)")
                                                    .foregroundStyle(tokens.statusWarning)
                                            } else if sub.compiledRuleCount > 0 {
                                                Text("· \(sub.compiledRuleCount.formatted())")
                                                    .monospacedDigit()
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if !sub.isBuiltInSeed {
                                        Button(role: .destructive) {
                                            Task { await blocker.removeSubscription(id: sub.id) }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .tint(tokens.statusDanger)
                                        .accessibilityLabel("Remove Subscription")
                                    }
                                }
                            }
                        } header: {
                            Text(category.rawValue)
                        }
                    }
                }

                Section("Add Custom Filter URL") {
                    TextField("Title (Optional)", text: $customTitle)
                    TextField("https://example.com/filters.txt", text: $customURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Category", selection: $customCategory) {
                        ForEach(FilterSubscription.Category.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }

                    Button {
                        let title = customTitle
                        let url = customURL
                        let cat = customCategory
                        Task {
                            if await blocker.addCustomSubscription(title: title, urlString: url, category: cat) {
                                customTitle = ""
                                customURL = ""
                            }
                        }
                    } label: {
                        Label("Subscribe", systemImage: "plus.circle")
                            .symbolRenderingMode(.monochrome)
                    }
                    .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blocker.isSyncing)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
            .navigationTitle("Shield & Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
