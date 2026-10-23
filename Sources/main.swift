import AppKit

// `--once` prints the current limits to stdout and exits: handy for checking that
// the keychain read and the API call work without involving the menu bar at all.
if CommandLine.arguments.contains("--once") {
    do {
        let snapshot = try UsageAPI.fetch()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for window in snapshot.windows {
            let reset = window.resetsAt.map { formatter.string(from: $0) } ?? "—"
            let name = window.name.padding(toLength: max(window.name.count, 22),
                                           withPad: " ", startingAt: 0)
            let used = String(format: "%5.1f", window.percentUsed)
            let left = String(format: "%5.1f", window.percentLeft)
            print("\(name)  використано \(used)%  залишилось \(left)%  скидання \(reset)")
        }
        if let spend = snapshot.spend {
            print("extra credits: \(spend.used) / \(spend.limit)  enabled=\(spend.enabled)")
        }
        for row in snapshot.weeklyBreakdown where row.percent > 0 {
            print("weekly \(row.name): \(Int(row.percent))%")
        }
        exit(0)
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        exit(1)
    }
}

// `--icon <path>` renders the menu bar mark to a PNG, for eyeballing it while
// tweaking the drawing.
if let index = CommandLine.arguments.firstIndex(of: "--icon"),
   let path = CommandLine.arguments.dropFirst(index + 1).first {
    let size = CommandLine.arguments.dropFirst(index + 2).first.flatMap { Double($0) } ?? 128
    let image = ClaudeMark.image(size: size, color: .black)
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the Mac unable to sleep after we are gone.
        controller?.prepareForTermination()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
app.run()
