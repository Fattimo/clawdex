import AppKit
import ClawdexGitHub

/// The rotating GitHub scorebug below the dog. Chains outlive agent sessions.
final class GitHubBoardController {
    private weak var pet: PetWindow?
    private var config: GitHubConfig?
    private var snapshot = GitHubSnapshot()
    private var scorebug: GitHubScorebugWindow?
    private var observers: [NSObjectProtocol] = []
    private var layingOut = false
    private var lastReady: [String: Bool] = [:]
    var onNotice: ((String, @escaping () -> Void) -> Void)?

    init(pet: PetWindow) {
        self.pet = pet
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: pet, queue: .main) { [weak self] _ in self?.layout() })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func update(config: GitHubConfig?, snapshot: GitHubSnapshot, visible: Bool) {
        self.config = config; self.snapshot = snapshot
        guard visible, let config, config.enabled else { clear(); return }
        let stacks = GitHubBoardSelection.recentStacks(snapshot.stacks(in: config))
        guard !stacks.isEmpty else { clear(); return }
        if scorebug == nil {
            let window = GitHubScorebugWindow()
            pet?.addChildWindow(window, ordered: .above)
            window.onSelect = { [weak self] id in self?.openStack(id) }
            scorebug = window
        }
        scorebug?.setItems(stacks.map { stack in
            let issue = problem(repository: stack.definition.repository)
            let glyph: String
            if issue != nil { glyph = "!" }
            else if stack.ready || stack.merged { glyph = "✓" }
            else if stack.label == "Needs you" || !stack.validOrder { glyph = "!" }
            else if stack.label == "Needs review" { glyph = "↗" }
            else { glyph = "◌" }
            let next = stack.definition.numbers.first { number in
                stack.pullRequests.contains { $0.number == number && $0.state == "OPEN" }
            }
            let detail = next.map { "\(stack.label) · #\($0)" } ?? stack.label
            return GitHubScorebugWindow.Item(id: stack.definition.id, title: stack.definition.name,
                glyph: glyph, status: issue ?? detail, compactStatus: issue == nil ? detail : "Offline")
        })
        pet?.companionBottomInset = CompanionLayout.floorGap + CompanionLayout.floorHeight
        layout(); scorebug?.orderFrontRegardless()
        for stack in stacks {
            guard snapshot.repositories.first(where: { $0.repository == stack.definition.repository })?.error == nil else { continue }
            if stack.ready, problem(repository: stack.definition.repository) == nil, lastReady[stack.definition.id] == false {
                onNotice?("\(stack.definition.name): the whole stack is ready.", { [weak self] in self?.openStack(stack.definition.id) })
            }
            lastReady[stack.definition.id] = stack.ready
        }
    }

    func anchor() { layout() }
    private func clear() {
        if let scorebug { pet?.removeChildWindow(scorebug); scorebug.close() }
        scorebug = nil; pet?.companionBottomInset = 0
    }
    private func problem(repository: String) -> String? {
        if let error = snapshot.repositories.first(where: { $0.repository == repository })?.error { return error }
        if !snapshot.receiverReady { return "Local receiver is not running" }
        if let error = snapshot.tunnelError { return error }
        if snapshot.tunnelURL == nil { return "Waiting for ngrok" }
        if config?.hookIDs[repository] == nil { return "Connect this repository's webhook" }
        if let error = snapshot.repositories.first(where: { $0.repository == repository })?.webhookError { return error }
        if snapshot.repositories.first(where: { $0.repository == repository })?.webhookURL != snapshot.tunnelURL { return "Connecting repository webhook" }
        return nil
    }
    private func layout() {
        guard !layingOut, let pet, let scorebug else { return }
        layingOut = true; defer { layingOut = false }
        pet.constrainCompanionToScreen()
        scorebug.setFrame(CompanionLayout.floorFrame(pet.frame), display: true)
        scorebug.contentView?.needsLayout = true
    }
    private func openStack(_ id: String) {
        guard let config, let stack = snapshot.stacks(in: config).first(where: { $0.definition.id == id }),
              let url = GitHubBoardNavigation.mergeURL(repository: stack.definition.repository,
                orderedNumbers: stack.definition.numbers, pullRequests: stack.pullRequests) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum GitHubBoardNavigation {
    static func mergeURL(repository: String, orderedNumbers: [Int], pullRequests: [GitHubPR]) -> URL? {
        guard let number = orderedNumbers.first(where: { number in
            pullRequests.contains { $0.number == number && $0.state == "OPEN" }
        }), let reference = try? PRReference(repository: repository, number: number),
              var components = URLComponents(url: reference.url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = "partial-pull-merging"
        return components.url
    }
}
