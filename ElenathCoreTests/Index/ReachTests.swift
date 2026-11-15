import ElenathCore
import Foundation
import Testing

@Suite("Reach")
struct ReachTests {
    let uni = Space(name: "Uni")
    let ideas = Space(name: "Ideas")
    let redCross = Space(name: "Red Cross", isSealed: true)
    let vault = Space(name: "Vault", isSealed: true)

    private var spaces: [Space] { [uni, redCross, ideas, vault] }

    private func reach(_ workplace: Workplace) -> Set<Container> {
        Reach(workplace: workplace, spaces: spaces).containers
    }

    @Test("A sealed space reads itself and nothing else")
    func sealedSpace() {
        #expect(reach(.space(redCross.id)) == [.space(redCross.id)])
        #expect(reach(.space(vault.id)) == [.space(vault.id)])
    }

    @Test("An unsealed space reads every unsealed space, and no sealed one")
    func unsealedSpace() {
        #expect(reach(.space(uni.id)) == [.space(uni.id), .space(ideas.id)])
        #expect(reach(.space(ideas.id)) == [.space(uni.id), .space(ideas.id)])
    }

    @Test("Everywhere means every unsealed space: no sealed space and not the Inbox")
    func everywhere() {
        #expect(reach(.everywhere) == [.space(uni.id), .space(ideas.id)])
    }

    @Test("The Inbox reads the Inbox only, and nothing else reads the Inbox")
    func inbox() {
        #expect(reach(.inbox) == [.inbox])
        for workplace in [Workplace.everywhere, .space(uni.id), .space(redCross.id)] {
            #expect(!Reach(workplace: workplace, spaces: spaces).allows(.inbox))
        }
    }

    @Test("A space that doesn't exist reads nothing")
    func unknownSpace() {
        #expect(reach(.space(SpaceID())).isEmpty)
        #expect(Reach(workplace: .everywhere, spaces: [redCross, vault]).containers.isEmpty)
    }

    @Test("A note's own container is the workplace its links are resolved from")
    func workplaceOfContainer() {
        #expect(Reach.workplace(of: .inbox) == .inbox)
        #expect(Reach.workplace(of: .space(uni.id)) == .space(uni.id))
    }
}
