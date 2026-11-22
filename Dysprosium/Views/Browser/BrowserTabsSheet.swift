import SwiftUI
import UIKit

/// Responsive Safari / Chrome-style Visual Tab Card Grid with live `WKWebView` page thumbnails,
/// `Standard` vs `Private` segmented scope switching, even column counts (`2` / `4`) across postures,
/// and a floating Liquid Glass bottom action bar.
/// Strictly obeys Liquid Glass layering: cards use pure semantic surfaces (`secondarySystemGroupedBackground`),
/// while `.glassEffect()` is confined exclusively to the floating bottom bar.
struct BrowserTabsSheet: View {
    private enum TabScope: String, CaseIterable, Identifiable {
        case standard
        case privateBrowsing

        var id: String { rawValue }
    }

    @Environment(\.dysprosiumTokens) private var tokens
    @Environment(\.dismiss) private var dismiss
    @Bindable var browserStore: CleanroomBrowserStore

    @State private var selectedScope: TabScope = .standard
    @State private var gridWidth: CGFloat = 460
    @State private var isConfirmingCloseAll: Bool = false
    @Namespace private var glassScopeNamespace

    private var standardTabs: [CleanroomWebKitSession] {
        browserStore.tabs.filter { !$0.isPrivate }
    }

    private var privateTabs: [CleanroomWebKitSession] {
        browserStore.tabs.filter(\.isPrivate)
    }

    private var visibleTabs: [CleanroomWebKitSession] {
        selectedScope == .privateBrowsing ? privateTabs : standardTabs
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
                if visibleTabs.isEmpty && selectedScope == .privateBrowsing {
                    privateEmptyState
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            if selectedScope == .standard, !browserStore.recentlyClosedTabs.isEmpty {
                                reopenClosedBanner
                            }

                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(visibleTabs) { tab in
                                    TabPreviewCardView(
                                        tab: tab,
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
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.width
            } action: { newWidth in
                gridWidth = newWidth
            }
            .safeAreaInset(edge: .bottom) {
                bottomGlassActionBar
            }
            .navigationTitle(selectedScope == .privateBrowsing ? "Private Tabs" : "Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                selectedScope = browserStore.activeSession.isPrivate ? .privateBrowsing : .standard
                browserStore.prepareTabSwitcherPreviews()
            }
            .confirmationDialog(
                selectedScope == .privateBrowsing
                    ? "Close All \(visibleTabs.count) Private Tabs?"
                    : "Close All \(visibleTabs.count) Tabs?",
                isPresented: $isConfirmingCloseAll,
                titleVisibility: .visible
            ) {
                Button(
                    selectedScope == .privateBrowsing
                        ? "Close \(visibleTabs.count) Private Tabs"
                        : "Close \(visibleTabs.count) Tabs",
                    role: .destructive
                ) {
                    withAnimation(.spring(duration: 0.28, bounce: 0.06)) {
                        browserStore.closeAllTabs(isPrivate: selectedScope == .privateBrowsing)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if selectedScope == .privateBrowsing {
                    Text("Private tabs and their ephemeral session data will be discarded.")
                } else {
                    Text("Closed tabs can be reopened from Recently Closed.")
                }
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
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

            Text("Private Browsing")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Private tabs use an isolated in-memory store and leave zero history, cookies, or cached data once closed.")
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
                    Text("New Private Tab")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tokens.onAccent)
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
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: isCompactWidth ? 8 : 10) {
                if visibleTabs.count >= 2 {
                    Button(role: .destructive) {
                        isConfirmingCloseAll = true
                    } label: {
                        if isCompactWidth {
                            Label("Close All", systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 22, height: 22)
                        } else {
                            Text("Close All")
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Close All")
                    .accessibilityIdentifier("tabs-close-all-button")
                } else {
                    Color.clear
                        .frame(width: 40, height: 36)
                        .allowsHitTesting(false)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    scopeSegmentButton(
                        scope: .standard,
                        title: "\(standardTabs.count) \(standardTabs.count == 1 ? "Tab" : "Tabs")",
                        symbol: "square.on.square",
                        activeColor: tokens.accent
                    )
                    scopeSegmentButton(
                        scope: .privateBrowsing,
                        title: privateTabs.isEmpty ? "Private" : "Private (\(privateTabs.count))",
                        symbol: "hand.raised.fill",
                        activeColor: tokens.privateAccent
                    )
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: Capsule())

                Spacer(minLength: 4)

                Button {
                    browserStore.openNewTab(
                        isPrivate: selectedScope == .privateBrowsing,
                        activate: true
                    )
                    dismiss()
                } label: {
                    Label(
                        selectedScope == .privateBrowsing ? "New Private Tab" : "New Tab",
                        systemImage: "plus"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 22, height: 22)
                }
                .tint(selectedScope == .privateBrowsing ? tokens.privateAccent : tokens.accent)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("tabs-new-tab-button")
            }
            .padding(.horizontal, isCompactWidth ? 12 : 16)
            .padding(.vertical, 10)
        }
    }

    private func scopeSegmentButton(
        scope: TabScope,
        title: String,
        symbol: String,
        activeColor: Color
    ) -> some View {
        let isSelected = (selectedScope == scope)
        return Button {
            withAnimation(.spring(duration: 0.25, bounce: 0.08)) {
                selectedScope = scope
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSelected ? tokens.onAccent : .primary)
            .padding(.horizontal, gridWidth < 430 ? 10 : 12)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule()
                        .fill(activeColor)
                        .glassEffectID("active-tab-scope", in: glassScopeNamespace)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reopenClosedBanner: some View {
        if let latest = browserStore.recentlyClosedTabs.first {
            HStack(spacing: 8) {
                Button {
                    _ = browserStore.reopenLastClosedTab()
                    dismiss()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.uturn.backward")
                            .symbolRenderingMode(.monochrome)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tokens.accent)

                        Text("Reopen Closed")
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
                .accessibilityLabel("Reopen Closed")
                .accessibilityIdentifier("tabs-reopen-closed-button")

                Spacer(minLength: 4)

                if browserStore.recentlyClosedTabs.count > 1 {
                    Menu {
                        ForEach(browserStore.recentlyClosedTabs) { entry in
                            Button {
                                browserStore.openNewTab(urlString: entry.urlString, isPrivate: false, activate: true)
                                dismiss()
                            } label: {
                                Label(entry.title, systemImage: "globe")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            browserStore.clearRecentlyClosedTabs()
                        } label: {
                            Label("Clear Recently Closed", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(browserStore.recentlyClosedTabs.count)")
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
                    .accessibilityLabel("Recently Closed Tabs List")
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
    let isActive: Bool
    let isFourColumn: Bool
    let pdfAppearanceMode: PDFAppearanceMode
    let canCloseOthers: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onCloseOthers: () -> Void
    let onClose: () -> Void

    private var activeTint: Color {
        tab.isPrivate ? tokens.privateAccent : tokens.accent
    }

    private var isStartPage: Bool {
        tab.currentURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tab.activePDF == nil
    }

    private var isPDFTab: Bool {
        tab.isViewingPDF || tab.isLoadingInlinePDF
    }

    private var viewportCanvasColor: Color {
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
                .accessibilityLabel("Close \(tab.displayTabTitle)")
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
                Label("Duplicate Tab", systemImage: "plus.square.on.square")
            }

            if canCloseOthers {
                Button(action: onCloseOthers) {
                    Label("Close Other Tabs", systemImage: "xmark.square")
                }
            }

            Divider()

            Button(role: .destructive, action: onClose) {
                Label("Close Tab", systemImage: "xmark")
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

            Text(tab.isPrivate ? "Private Start" : "Start Page")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).opacity(0.65))
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
                Text(pdf.pageCount > 0 ? "PDF · \(pdf.pageCount)p" : "PDF")
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
                .foregroundStyle(tokens.onAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(activeTint, in: Capsule())
            }
        }
        .padding(6)
    }
}
