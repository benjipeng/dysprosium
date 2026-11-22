import SwiftUI

/// Compact `.insetGrouped` sheet presented from the `+` toolbar action in `Downloads`,
/// keeping URL intake out of permanent screen real estate while supporting direct HTTP Range and HLS URLs.
struct NewTransferSheet: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""
    @Binding var selectedLanes: Int
    let onSubmit: (URL, Int) -> Void

    @FocusState private var isFieldFocused: Bool

    private static let lanePresets = [1, 4, 8, 16]

    private var trimmedURL: URL? {
        let cleaned = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host() != nil else {
            return nil
        }
        return url
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.secondary)

                        TextField("https://example.com/video.mp4 or .m3u8", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .focused($isFieldFocused)
                            .onSubmit(submitAndDismiss)
                            .accessibilityIdentifier("intake-url-field")

                        if !urlText.isEmpty {
                            Button {
                                urlText = ""
                            } label: {
                                Label("Clear", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !first.isEmpty {
                                urlText = first
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(tokens.accent)
                        .accessibilityIdentifier("intake-paste-button")
                    }
                } header: {
                    Text("Source URL")
                } footer: {
                    Text("Direct files use parallel HTTP 206 byte-range slices; .m3u8 playlists remux losslessly to .mp4; webpage URLs open in Browser.")
                }

                Section("Concurrency") {
                    Picker("Parallel Lanes", selection: $selectedLanes) {
                        ForEach(Self.lanePresets, id: \.self) { count in
                            Text(count == 1 ? "1× Serial" : "\(count)× Range Split")
                                .tag(count)
                        }
                    }
                    .accessibilityIdentifier("intake-lanes-menu")
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
            .navigationTitle("New Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        submitAndDismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedURL == nil)
                    .accessibilityIdentifier("intake-fetch-button")
                }
            }
            .onAppear {
                isFieldFocused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submitAndDismiss() {
        guard let url = trimmedURL else { return }
        onSubmit(url, selectedLanes)
        dismiss()
    }
}
