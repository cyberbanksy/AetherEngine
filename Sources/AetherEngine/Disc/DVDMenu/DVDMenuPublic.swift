import Foundation
import CoreGraphics

// Host-facing DVD menu types (docs/dvd-menus.md, docs/api.md "DVD menus").

/// How a DVD-Video image starts when it is loaded.
public enum DVDStartMode: Sendable, Equatable {
    /// Play the main title directly through the normal pipeline ("Skip to Movie"). The default, and
    /// exactly the behaviour of every release before DVD menus existed.
    case mainTitle
    /// Run the disc from its first-play program chain, which normally lands on the disc's own menu
    /// ("Play Disc"). Discs without navigation data fall back to `.mainTitle`.
    case menu
}

/// Arrow-key navigation inside a DVD menu.
public enum DVDMenuDirection: Sendable, Equatable {
    case up, down, left, right
}

/// The disc menus a remote can call.
public enum DVDMenuKey: Sendable, Equatable {
    /// "Top Menu" / "Title": the disc's title menu.
    case title
    /// "Menu": the current title set's root menu.
    case root
    case chapter
    case audio
    case subtitle
    case angle
}

/// One selectable button of the menu on screen.
public struct DVDMenuButton: Sendable, Equatable, Identifiable {
    /// Button number (1-36), stable for the menu page.
    public let id: Int
    /// The button's rectangle normalized to the menu picture (0...1, top-left origin). Multiply by the
    /// on-screen video rect to place focus rings or hit areas.
    public let frame: CGRect
    /// Selecting this button runs it immediately (no OK press needed).
    public let isAutoAction: Bool

    public init(id: Int, frame: CGRect, isAutoAction: Bool) {
        self.id = id
        self.frame = frame
        self.isAutoAction = isAutoAction
    }
}

/// Live state of a disc running with `LoadOptions.dvdStartMode == .menu`, published as `AetherEngine.dvdMenu`.
public struct DVDMenuState: Sendable, Equatable {
    /// A disc menu (or first-play) is on screen and the remote / touch input drives it.
    public let isInMenu: Bool
    /// A title is playing through the normal playback pipeline; `dvdMenu(_:)` returns to the menu.
    public let isPlayingTitle: Bool
    /// The menu picture is a still (waiting for input or for its still time to run out).
    public let isStill: Bool
    /// Buttons of the menu page on screen (empty when there are none).
    public let buttons: [DVDMenuButton]
    /// The highlighted button's id, nil when the page has no buttons.
    public let highlightedButton: Int?
    /// Disc title number (1-based) and chapter of the current position.
    public let title: Int
    public let chapter: Int

    public init(isInMenu: Bool, isPlayingTitle: Bool, isStill: Bool, buttons: [DVDMenuButton],
                highlightedButton: Int?, title: Int, chapter: Int) {
        self.isInMenu = isInMenu
        self.isPlayingTitle = isPlayingTitle
        self.isStill = isStill
        self.buttons = buttons
        self.highlightedButton = highlightedButton
        self.title = title
        self.chapter = chapter
    }
}

extension DVDMenuState {
    init(_ s: DVDMenuSnapshot) {
        let w = Double(max(1, s.menuSize.width)), h = Double(max(1, s.menuSize.height))
        let inMenu = s.domain != .title
        let buttons = inMenu ? s.buttons.map {
            DVDMenuButton(id: $0.number,
                          frame: CGRect(x: Double($0.x0) / w, y: Double($0.y0) / h,
                                        width: Double($0.x1 - $0.x0 + 1) / w, height: Double($0.y1 - $0.y0 + 1) / h),
                          isAutoAction: $0.autoAction)
        } : []
        self.init(isInMenu: inMenu, isPlayingTitle: s.isWaitingForTitle, isStill: s.isStill, buttons: buttons,
                  highlightedButton: buttons.isEmpty ? nil : s.highlightedButton,
                  title: s.titleNumber, chapter: s.chapter)
    }
}

extension DVDMenuKey {
    var menuType: DVDMenuType {
        switch self {
        case .title: .title
        case .root: .root
        case .chapter: .chapter
        case .audio: .audio
        case .subtitle: .subpicture
        case .angle: .angle
        }
    }
}

extension DVDMenuDirection {
    var direction: DVDDirection {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}
