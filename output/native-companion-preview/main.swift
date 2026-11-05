import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let scene = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 350))
scene.wantsLayer = true
scene.layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .gray)!.cgColor
let host = NSWindow(contentRect: scene.frame, styleMask: .borderless, backing: .buffered, defer: false)
host.contentView = scene
let pet = NSRect(x: 208, y: 92, width: 144, height: 156)
let image = NSImageView(frame: pet.insetBy(dx: 8, dy: 8))
image.image = NSImage(contentsOfFile: "output/pr-watch/dog-idle.webp")
image.imageScaling = .scaleProportionallyUpOrDown
scene.addSubview(image)
var panels: [NSWindow] = []
for (index, name) in ["app", "api", "clawdex", "web"].enumerated() {
    let panel = PillWindow()
    let left = index.isMultiple(of: 2)
    let rect = CompanionLayout.sessionFrame(index: index / 2, pet: pet, onLeft: left)
    panel.setContent(label: name, lit: index != 1, accent: left ? .systemOrange : .systemBlue, fixedWidth: rect.width)
    let view = panel.contentView!; panel.contentView = nil; view.frame = rect; scene.addSubview(view)
    panels.append(panel)
}
let floor = GitHubScorebugWindow()
var card = GitHubScorebugWindow.Item(id: "billing", title: "Add usage-based billing to the account page", status: "2/2 ready",
    number: 60005, stackPosition: "2/3", unresolvedReviewCount: 3,
    createdAt: Date().addingTimeInterval(-86400 * 4), updatedAt: Date().addingTimeInterval(-7200), tone: .ready)
floor.setItems([card])
let floorView = floor.contentView!; floor.contentView = nil
floorView.frame = CompanionLayout.floorFrame(pet); scene.addSubview(floorView)
let bubble = SpeechBubbleWindow()
let size = bubble.setContent(source: "app", message: "Billing is green. Ready for review.", isFinal: true, accent: .systemOrange)
let bubbleView = bubble.contentView!; bubble.contentView = nil
bubbleView.frame = NSRect(x: pet.midX - size.width / 2, y: pet.maxY + 6, width: size.width, height: size.height)
scene.addSubview(bubbleView)
for (theme, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
    let appearance = NSAppearance(named: theme)!
    scene.appearance = appearance; host.appearance = appearance
    for (tone, suffix) in [(GitHubScorebugTone.ready, "ready"), (.pending, "pending"), (.failed, "failed"), (.neutral, "draft")] {
        card.tone = tone; floor.setItems([card])
        appearance.performAsCurrentDrawingAppearance {
            scene.layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.08, of: .gray)!.cgColor
            scene.layoutSubtreeIfNeeded()
            let bitmap = scene.bitmapImageRepForCachingDisplay(in: scene.bounds)!
            scene.cacheDisplay(in: scene.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "output/native-companion-preview/\(name)-\(suffix).png"))
        }
    }
}
host.orderOut(nil)
print("Native companion preview rendered")
