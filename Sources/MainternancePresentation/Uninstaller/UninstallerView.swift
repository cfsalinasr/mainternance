import MainternanceDomain
import SwiftUI

/// Renders `UninstallerViewState`; every rule and every sentence lives in the state and `UninstallerText`. Lists the
/// apps when it appears, never at launch.
public struct UninstallerView: View {
    private let state: UninstallerViewState

    public init(state: UninstallerViewState) {
        self.state = state
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list.frame(width: 260)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await state.appear() }
        .sheet(isPresented: Binding(
            get: { state.isReviewing },
            set: {
                if !$0 {
                    state.cancelReview()
                }
            }
        )) {
            UninstallerReviewSheet(state: state)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(UninstallerText.searchPrompt, text: Bindable(state).searchText)
                .textFieldStyle(.roundedBorder)
                .padding([.top, .horizontal], 10)
            if state.isListing, state.apps.isEmpty {
                ProgressView(UninstallerText.listing).padding()
                Spacer()
            } else if state.apps.isEmpty {
                ContentUnavailableView(UninstallerText.noApps, systemImage: "trash")
            } else if state.visibleApps.isEmpty {
                Text(UninstallerText.noMatch).font(.system(size: 12)).foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                List(selection: Binding(get: { state.selectedID }, set: { id in state.startSelect(id) })) {
                    ForEach(state.visibleApps) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName).font(.system(size: 13, weight: .medium))
                            if let version = app.version.map(DisplayText.clean), !version.isEmpty {
                                Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .tag(app.id)
                        .accessibilityElement(children: .combine)
                    }
                }
                .disabled(!state.canChange)
                .accessibilityLabel("Installed apps")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.isLoadingDetails {
            ProgressView(UninstallerText.loadingDetails).padding(20)
        } else if let details = state.details {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(UninstallerText.title).font(.title2.bold())
                    Text(UninstallerText.intro).font(.system(size: 12)).foregroundStyle(.secondary)
                    appCard(details)
                    if details.leftovers.isEmpty {
                        Text(UninstallerText.nothingLeft).foregroundStyle(.secondary)
                    }
                    ForEach([LeftoverMatch.identifier, .nameOnly, .launchAgent], id: \.self) { group($0) }
                    footer
                    UninstallerResultCard(state: state)
                }
                .padding(20)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ContentUnavailableView(
                    UninstallerText.selectApp, systemImage: "trash",
                    description: Text(UninstallerText.selectAppDetail)
                )
                UninstallerResultCard(state: state).padding(.horizontal, 20)
            }
        }
    }

    private func appCard(_ details: AppDetails) -> some View {
        HStack(spacing: 12) {
            checkbox(isOn: state.includesApp, label: "Include \(details.app.displayName)") { state.toggleApp() }
            VStack(alignment: .leading, spacing: 2) {
                PreviewListRow(
                    title: UninstallerText.appTitle(details.app), subtitle: UninstallerText.appCardNote,
                    trailing: UninstallerText.size(details)
                )
                if state.showsQuitNote {
                    Text(UninstallerText.quitFirst).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func group(_ match: LeftoverMatch) -> some View {
        let items = state.leftovers(match)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(UninstallerText.header(match)).font(.headline)
                if match == .launchAgent {
                    Text(UninstallerText.launchAgentWarning).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ leftover: Leftover) -> some View {
        HStack(spacing: 10) {
            checkbox(
                isOn: state.isSelected(leftover: leftover.id), label: "Include \(leftover.displayName)"
            ) { state.toggleLeftover(leftover.id) }
            VStack(alignment: .leading, spacing: 2) {
                PreviewListRow(
                    title: leftover.displayName, subtitle: UninstallerText.subtitle(leftover),
                    trailing: UninstallerText.size(leftover)
                )
                if let reason = state.failureReason(leftover.id) {
                    Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .solidCard()
    }

    private func checkbox(isOn: Bool, label: String, toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!state.canChange)
            .accessibilityLabel(label)
    }

    private var footer: some View {
        HStack {
            Text(state.selectedText).font(.headline).monospacedDigit()
            Spacer()
            if state.isMoving {
                ProgressView(UninstallerText.moving).controlSize(.small)
            }
            Button(UninstallerText.review) { state.review() }
                .disabled(!state.canReview)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Lists what would move to the Trash before anything moves")
        }
        .accessibilityElement(children: .contain)
    }
}

/// What the last move to the Trash really did: moved items and space, then what could not move and why.
struct UninstallerResultCard: View {
    let state: UninstallerViewState

    var body: some View {
        if state.showsResultCard {
            VStack(alignment: .leading, spacing: 4) {
                if let result = state.resultText {
                    Text(result).font(.system(size: 13, weight: .medium))
                    Text(UninstallerText.trashNote).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(state.failureLines, id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .solidCard()
            .accessibilityElement(children: .combine)
        }
    }
}
