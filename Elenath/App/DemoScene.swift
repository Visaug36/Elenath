import CoreGraphics

/// What a `-demo` screenshot run asks for. Ignored without `-demo`.
///
/// - `-demoAppearance night|dawn|system`
/// - `-demoWindowSize 1280x800`: the main window's content size
/// - `-demoScene today|note|inbox|space|search|sealed|capture|onboarding|settings`: what the window shows
struct DemoScene: Sendable, Equatable {
    /// The screens a screenshot can ask for.
    enum Screen: String, Sendable {
        case today
        /// A note in the editor.
        case note
        case inbox
        /// A space's contents.
        case space
        /// Search results.
        case search
        /// Inside the sealed space.
        case sealed
        /// The Quick Capture panel over the window.
        case capture
        /// Onboarding's first page.
        case onboarding
        /// The Settings window.
        case settings
    }

    var appearance: AppearanceChoice?
    var windowSize: CGSize?
    var screen: Screen?

    var isEmpty: Bool {
        appearance == nil && windowSize == nil && screen == nil
    }

    static func parse(_ arguments: [String]) -> DemoScene {
        var scene = DemoScene()
        scene.appearance = value(after: "-demoAppearance", in: arguments).flatMap { AppearanceChoice(rawValue: $0) }
        scene.windowSize = value(after: "-demoWindowSize", in: arguments).flatMap(size(from:))
        scene.screen = value(after: "-demoScene", in: arguments).flatMap { Screen(rawValue: $0) }
        return scene
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Parses "1280x800".
    private static func size(from text: String) -> CGSize? {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
