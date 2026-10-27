import SwiftUI

struct SearchHistorySection: View {
    let history: [String]
    let saved: [String]
    let open: (String) -> Void
    let star: (String) -> Void
    let remove: (String) -> Void
    let clear: () -> Void
    var identifierPrefix = "history.query."
    @State private var confirmingClear = false
    var body: some View {
        Section {
            ForEach(history, id: \.self) { query in
                HStack {
                    Button { open(query) } label: { Label(query, systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.accessibilityIdentifier(identifierPrefix + query)
                    Button { star(query) } label: { Image(systemName: saved.contains(query) ? "star.fill" : "star").foregroundStyle(.yellow).frame(width: 36, height: 36) }
                        .accessibilityLabel(L10n.text("Saved Searches")).accessibilityIdentifier("history.star." + query)
                }.buttonStyle(.borderless)
                    .swipeActions { Button(L10n.text("Remove"), role: .destructive) { remove(query) } }
            }
        } header: {
            HStack {
                Text(L10n.text("Search History"))
                Spacer()
                Button { confirmingClear = true } label: { Image(systemName: "trash") }
                    .disabled(history.isEmpty).accessibilityLabel(L10n.text("Clear History")).accessibilityIdentifier("history.clear")
            }
        }
        .alert(L10n.text("Clear History?"), isPresented: $confirmingClear) {
            Button(L10n.text("Clear History"), role: .destructive, action: clear)
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Search history will be deleted. Saved searches will be kept.")) }
    }
}

/// Search overlays share the same compact rows as tag completions. The library
/// management screen retains SearchHistorySection and its native List actions.
struct SearchHistoryPanel: View {
    let history: [String]
    let saved: [String]
    let open: (String) -> Void
    let star: (String) -> Void
    let remove: (String) -> Void
    let clear: () -> Void
    @State private var confirmingClear = false
    private var recentHistory: [String] { Array(history.prefix(5)) }
    private var savedQueries: [String] {
        var seen = Set<String>()
        return saved.filter { seen.insert($0).inserted }
    }
    static func height(availableHeight: CGFloat) -> CGFloat {
        // The search field occupies 56 points; leave a small gap above the keyboard.
        max(0, availableHeight - 56 - 12)
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                SearchHistoryPanelHeader(title: "Search History", clear: { confirmingClear = true }, clearDisabled: history.isEmpty)
                if history.isEmpty {
                    Text(L10n.text("Nothing Saved Yet")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).searchSuggestionRow()
                }
                ForEach(recentHistory, id: \.self) { query in
                    HStack(spacing: 8) {
                        Button { open(query) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                Text(query).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 4)
                            }.frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                        }.accessibilityIdentifier("history.query." + query)
                        Button { star(query) } label: {
                            Image(systemName: saved.contains(query) ? "star.fill" : "star")
                                .foregroundStyle(.yellow).frame(width: 36, height: 46)
                        }.accessibilityLabel(L10n.text("Saved Searches")).accessibilityIdentifier("history.star." + query)
                    }.searchSuggestionRow()
                        .contextMenu { Button(L10n.text("Remove"), role: .destructive) { remove(query) } }
                        .accessibilityAction(named: L10n.text("Remove")) { remove(query) }
                    if query != recentHistory.last { Divider() }
                }
                if !savedQueries.isEmpty {
                    SearchHistoryPanelHeader(title: "Saved Searches").padding(.top, 20)
                    ForEach(savedQueries, id: \.self) { query in
                        Button { open(query) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "star.fill").foregroundStyle(.yellow)
                                Text(query).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 4)
                            }.searchSuggestionRow()
                        }.accessibilityIdentifier("history.saved." + query)
                            .contextMenu { Button(L10n.text("Remove"), role: .destructive) { star(query) } }
                        if query != savedQueries.last { Divider() }
                    }
                }
            }
        }.buttonStyle(.plain)
            .alert(L10n.text("Clear History?"), isPresented: $confirmingClear) {
                Button(L10n.text("Clear History"), role: .destructive, action: clear)
                Button(L10n.text("Cancel"), role: .cancel) {}
            } message: { Text(L10n.text("Search history will be deleted. Saved searches will be kept.")) }
    }
}

private struct SearchHistoryPanelHeader: View {
    let title: String
    var clear: (() -> Void)? = nil
    var clearDisabled = false
    var body: some View {
        HStack {
            Text(L10n.text(title)).fontWeight(.semibold).foregroundStyle(.secondary)
            Spacer()
            if let clear {
                Button(action: clear) { Image(systemName: "trash").frame(width: 36, height: 28) }
                    .disabled(clearDisabled).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Clear History")).accessibilityIdentifier("history.clear")
            }
        }.font(.body).frame(height: 28).padding(.top, 6).padding(.horizontal, 12)
    }
}

extension View {
    func searchSuggestionRow() -> some View {
        font(.subheadline).frame(minHeight: 46).padding(.horizontal, 12).contentShape(Rectangle())
    }
}

struct SearchHistorySettings: View {
    let booru: Bool
    @SwiftUI.AppStorage private var days: Int
    @SwiftUI.AppStorage private var remember: Bool
    init(booru: Bool = false) {
        self.booru = booru
        _remember = .init(wrappedValue: true, booru ? "booru.rememberHistory" : "search.rememberHistory", store: booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults)
        _days = .init(wrappedValue: 0, "search.retentionDays", store: booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults)
    }
    var body: some View {
        Section(L10n.text("Search History")) {
            Toggle(L10n.text("Remember Search History"), isOn: $remember).accessibilityIdentifier("settings.rememberHistory")
            Picker(L10n.text("Keep History"), selection: $days) {
                Text(L10n.text("3 Days")).tag(3)
                Text(L10n.text("7 Days")).tag(7)
                Text(L10n.text("30 Days")).tag(30)
                Text(L10n.text("Always")).tag(0)
            }.disabled(!remember).accessibilityIdentifier("settings.historyRetention")
        }
    }
}
