import Foundation

/// Where the user is working.
public enum Workplace: Hashable, Sendable {
    /// Inside one space.
    case space(SpaceID)
    /// Views that belong to no space: Today, search everywhere, jump to a note.
    case everywhere
    case inbox
}

/// The containers whose content a workplace may read. **This is the only place that decides it.**
///
/// | Workplace | May read |
/// |---|---|
/// | a sealed space | that space only |
/// | an unsealed space | every unsealed space |
/// | everywhere | every unsealed space |
/// | the Inbox | the Inbox only |
/// | a space that doesn't exist | nothing |
///
/// A sealed space's content is read only from inside it, and nothing else is read from inside it. The
/// Inbox is read only from the Inbox: its items are used for nothing except filing them.
public struct Reach: Hashable, Sendable {
    public let workplace: Workplace
    public let containers: Set<Container>

    public init(workplace: Workplace, spaces: [Space]) {
        self.workplace = workplace
        let mixing = Set(spaces.filter { !$0.isSealed }.map { Container.space($0.id) })
        switch workplace {
        case .inbox:
            containers = [.inbox]
        case .everywhere:
            containers = mixing
        case .space(let id):
            if let space = spaces.first(where: { $0.id == id }) {
                containers = space.isSealed ? [.space(id)] : mixing
            } else {
                containers = []
            }
        }
    }

    public func allows(_ container: Container) -> Bool {
        containers.contains(container)
    }

    /// The workplace a note's own container is: what is used to resolve its links and find its
    /// backlinks.
    public static func workplace(of container: Container) -> Workplace {
        switch container {
        case .inbox: .inbox
        case .space(let id): .space(id)
        }
    }
}
