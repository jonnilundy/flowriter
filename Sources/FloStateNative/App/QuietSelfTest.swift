import AppKit
import FloCore
import FloKit

/// Flowriter: `--ui-selftest quiet <post> <out>` (VM only). The writing space works offline: open a
/// post and type for a while (typing, Return, pauses), and no menu offers AI items.
/// scripts/quiet-vm-test.sh watches the process's sockets from outside while this runs (any socket
/// fails the run) and checks that the app binary calls no Security framework item or key API.
@MainActor
enum QuietSelfTest {
    typealias T = SelfTestRunner

    static func run(_ ctx: T.Context) async {
        let prose = Integrity.proseLines(ctx)
        guard prose.count >= 2 else { T.expect(false, "post has prose"); return }
        var keys = 0
        let t0 = Date()
        for (round, n) in prose.prefix(3).enumerated() {
            await Integrity.setup(ctx, NSRange(location: NSMaxRange(Integrity.lineRange(ctx, n)), length: 0))
            for ch in " Another sentence that keeps the writer going for a while." {
                Integrity.key(ctx, String(ch), code: ch == " " ? 49 : 0); keys += 1
                await T.pause(0.012)
            }
            Integrity.key(ctx, "\r", code: 36); keys += 1
            for ch in "A new paragraph, typed at speed, round \(round + 1)." {
                Integrity.key(ctx, String(ch), code: ch == " " ? 49 : 0); keys += 1
                await T.pause(0.012)
            }
            await T.pause(2.0)   // idle: anything that would wake up after a pause gets its chance
        }
        T.log(String(format: "typed %d keys over %.1f s", keys, Date().timeIntervalSince(t0)))
        // the menus as the app builds them (FloApp): nothing about AI
        let menu = MainMenu.build(target: MenuRouter())
        FlowriterSpace.installMenus(in: menu, focused: { nil })
        func titles(_ m: NSMenu) -> [String] { m.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
        let all = titles(menu)
        let words = ["AI", "Assistant", "Generate", "Writing Checks", "Check Feedback"]
        let ai = all.filter { t in words.contains { w in t.range(of: "\\b\(w)\\b", options: .regularExpression) != nil } }
        T.expect(ai.isEmpty, "no AI items in the menus (\(all.count) items): \(ai)")
        T.expect(all.contains("Appearance") && all.contains("Open…"), "View > Appearance and File > Open… are there")
        ctx.model.flushDirtyFiles()
    }
}
