// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The "apps to leave alone" block that lives INSIDE a mouse feature's own
/// section in Settings (issue #358), right under the switch it holds back, so
/// the list is where the user is already looking. One list per feature: the
/// same view with a different scope.
///
/// It stays a single quiet row while nothing is listed, and comes up open when
/// the feature already has exceptions, so a page with every mouse feature on
/// never turns into a wall of lists.
struct MouseExceptionsList: View {
    let scope: MouseExceptionScope

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var exceptions = MouseAppExceptions.shared
    @State private var isExpanded: Bool
    @State private var showingAppPicker = false
    @State private var cachedSortedApps: [String] = []
    @State private var cachedListSignature: [String] = []

    init(scope: MouseExceptionScope) {
        self.scope = scope
        _isExpanded = State(initialValue: !MouseAppExceptions.shared.list(scope).isEmpty)
    }

    private var text: MouseExceptionStrings { FeatureStrings.mouseExceptions(l10n.language) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Keep icon/name resolution out of the collapsed tree — this page
            // hosts several of these lists and resolving apps is not free.
            if isExpanded {
                ForEach(cachedSortedApps, id: \.self) { bundleID in
                    HStack(spacing: 9) {
                        Image(nsImage: InstalledApps.icon(for: bundleID))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(InstalledApps.name(for: bundleID))
                        Spacer()
                        Button {
                            exceptions.remove(bundleID, from: scope)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(text.removeButton)
                    }
                }

                Button {
                    showingAppPicker = true
                } label: {
                    Label(text.addButton, systemImage: "plus")
                }
                .controlSize(.small)
                // Rows inside a disclosure group center themselves; the button
                // belongs under the list it adds to.
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(text.caption(for: scope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack {
                Text(text.listTitle)
                Spacer()
                let count = exceptions.list(scope).count
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .onAppear { refreshSortedAppsIfNeeded() }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { refreshSortedAppsIfNeeded(force: true) }
        }
        .onChange(of: exceptions.lists) { _, _ in
            refreshSortedAppsIfNeeded(force: true)
        }
        .sheet(isPresented: $showingAppPicker) {
            appPickerSheet
        }
    }

    private var appPickerSheet: some View {
        let listed = Set(exceptions.list(scope))
        return AppPickerView(canBrowseApplications: true) {
            showingAppPicker = false
        } onSelect: { url in
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            exceptions.add(bundleID, to: scope)
            showingAppPicker = false
        } loadApps: {
            InstalledApps.installedBundleApplications(excluding: listed,
                                                       includeRunningApplications: true)
        }
    }

    private func refreshSortedAppsIfNeeded(force: Bool = false) {
        let current = exceptions.list(scope)
        guard force || current != cachedListSignature else { return }
        cachedListSignature = current
        cachedSortedApps = current.sorted {
            InstalledApps.name(for: $0).localizedCaseInsensitiveCompare(InstalledApps.name(for: $1))
                == .orderedAscending
        }
    }
}
