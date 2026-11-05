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
    private var recencyTimer: Timer?
    private var visible = true
    private var destinations: [String: URL] = [:]
    var onNotice: ((String, @escaping () -> Void) -> Void)?

    init(pet: PetWindow) {
        self.pet = pet
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: pet, queue: .main) { [weak self] _ in self?.layout() })
        }
        // Expire cached items locally even when GitHub sends no new webhook.
        recencyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.update(config: self.config, snapshot: self.snapshot, visible: self.visible)
        }
    }
    deinit { recencyTimer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    func update(config: GitHubConfig?, snapshot: GitHubSnapshot, visible: Bool) {
        self.config = config; self.snapshot = snapshot; self.visible = visible
        guard visible, let config, config.enabled else { clear(); return }
        let selection = GitHubBoardSelection.recentPullRequests(snapshot.stacks(in: config))
        guard !selection.isEmpty else { clear(); return }
        var seen = Set<String>()
        let stacks = selection.compactMap { seen.insert($0.stack.definition.id).inserted ? $0.stack : nil }
        if scorebug == nil {
            let window = GitHubScorebugWindow()
            pet?.addChildWindow(window, ordered: .above)
            window.onSelect = { [weak self] id in
                if let url = self?.destinations[id] { NSWorkspace.shared.open(url) }
            }
            scorebug = window
        }
        destinations.removeAll()
        let items = selection.compactMap { entry -> GitHubScorebugWindow.Item? in
            guard let item = Self.item(for: entry.stack, pullRequest: entry.pr,
                issue: problem(repository: entry.stack.definition.repository)) else { return nil }
            destinations[item.id] = GitHubBoardNavigation.mergeURL(repository: entry.stack.definition.repository,
                orderedNumbers: [entry.pr.number], pullRequests: [entry.pr])
            return item
        }
        scorebug?.setItems(items)
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

    static func item(for stack: GitHubStack, pullRequest: GitHubPR? = nil, issue: String?) -> GitHubScorebugWindow.Item? {
        guard let pr = pullRequest ?? stack.bottomPR else { return nil }
        let tone: GitHubScorebugTone
        if issue != nil { tone = .neutral }
        else if pr.state == "OPEN", pr.statusCheckRollup?.contains(where: \.failed) == true { tone = .failed }
        else if pr.isDraft { tone = .neutral }
        else if pr.health == .ready { tone = .ready }
        else if [.failed, .blocked].contains(pr.health) { tone = .failed }
        else if [.checking, .review].contains(pr.health) { tone = .pending }
        else { tone = .neutral }
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        let position = stack.definition.numbers.firstIndex(of: pr.number).map { $0 + 1 } ?? 1
        return GitHubScorebugWindow.Item(id: "\(stack.definition.repository.lowercased())#\(pr.number)", title: pr.title, status: issue ?? pr.explanation,
            number: pr.number, stackPosition: stack.definition.numbers.count > 1 ? "\(position)/\(stack.definition.numbers.count)" : nil,
            unresolvedReviewCount: pr.unresolvedReviewCount, createdAt: date(pr.createdAt), updatedAt: date(pr.updatedAt), tone: tone)
    }

    func anchor() { layout() }
    private func clear() {
        if let scorebug { pet?.removeChildWindow(scorebug); scorebug.close() }
        scorebug = nil; pet?.companionBottomInset = 0
        destinations.removeAll()
    }
    private func problem(repository: String) -> String? {
        if let error = snapshot.repositories.first(where: { $0.repository == repository })?.error { return error }
        if config?.webhooksEnabled != true { return nil }
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
