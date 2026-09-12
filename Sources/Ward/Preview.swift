import SwiftUI
import AppKit

/// `Ward --render <dir>` rasterises each pane to a PNG without opening a window.
/// Useful for checking layout and for regenerating the screenshots in the README.
@MainActor
enum PreviewShots {

    static func writeAll(to directory: String) {
        // Seeding a page is read-only. Never call teach() from here — it would write
        // a made-up lesson into the real rulebook just for a screenshot.
        Engine.shared.seedForPreview(title: "The Problem With Forza Horizon 6")

        let panes: [(String, CGFloat, AnyView)] = [
            ("overview", 720, AnyView(OverviewPane())),
            ("apps",     720, AnyView(AppsPane())),
            ("sites",    720, AnyView(SitesPane())),
            ("content",  720, AnyView(ContentPane())),
            ("session",  720, AnyView(SessionPane())),
            ("practice", 720, AnyView(PracticePane())),

        ]
        for (name, width, view) in panes {
            write(view, name: name, width: width, to: directory)
        }
        write(AnyView(HistoryPane()), name: "history", width: 760, to: directory, height: 1180)
        write(AnyView(Welcome()), name: "welcome", width: 600, to: directory, height: 560)
        write(AnyView(ChallengeCard()), name: "challenge-settings", width: 520, to: directory)
        for (name, kind) in [("typing", ChallengeKind.typing), ("sum", .arithmetic),
                             ("memory", .memory), ("blocks", .blockSort),
                             ("lights", .lightsOut), ("wait", .wait)] {
            let puzzle = PuzzleMaker.make(kind, iq: 130)
            let pending = Challenges.Pending(gate: .exception, puzzle: puzzle, action: {})
            write(AnyView(ChallengeSheet(pending: pending)),
                  name: "challenge-\(name)", width: 560, to: directory)
        }

        // Same pane at 100% and 150%, to confirm zoom re-lays-out rather than
        // magnifying: the type gets bigger, the column does not.
        write(AnyView(BehaviourSettings()), name: "settings-behaviour", width: 520, to: directory)
        write(AnyView(GeneralSettings()), name: "settings-general", width: 520, to: directory)
        write(AnyView(SitesPane()), name: "zoom-100", width: 620, to: directory, scale: 1.0)
        write(AnyView(SitesPane()), name: "zoom-150", width: 620, to: directory, scale: 1.5)

        // Just the tester, clipped, for a close look at the lean scale.
        write(AnyView(ContentPane().frame(height: 520, alignment: .top).clipped()),
              name: "tester", width: 720, to: directory)
    }

    static func write<V: View>(_ view: V, name: String, width: CGFloat,
                               to directory: String, scale: CGFloat = 1,
                               height: CGFloat? = nil) {
        // Panes that fill themselves in `onAppear` are laid out before that runs, so
        // the renderer would size to the empty state and clip. An explicit height
        // gives them room; the real panes live in a ScrollView and don't need it.
        let renderer = ImageRenderer(content:
            view.frame(width: width, height: height, alignment: .top)
                .padding(18)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.uiScale, scale)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("could not render \(name)\n".data(using: .utf8)!)
            return
        }
        let path = "\(directory)/\(name).png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("\(path)  \(Int(image.size.width))x\(Int(image.size.height))")
        } catch {
            // Printing a path that was never written is worse than saying nothing.
            FileHandle.standardError.write(
                "could not write \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
}
