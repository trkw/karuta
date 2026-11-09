// `make test`: checks for KarutaCore. A plain executable because the Command Line Tools have
// neither XCTest nor the Swift Testing macros. Exits 1 when any check fails.
import Foundation
import KarutaCore

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print(condition ? "✔ \(name)" : "✘ \(name)")
    if !condition { failures += 1 }
}
func equal(_ name: String, _ actual: String, _ expected: String) {
    check(name + (actual == expected ? "" : " (got \"\(actual)\", expected \"\(expected)\")"), actual == expected)
}

let utc = TimeZone(identifier: "UTC")!
// 2026-10-31 13:05:09 UTC
let date = Date(timeIntervalSince1970: 1_793_451_909)
func name(_ template: String, app: String? = "Safari", timeZone: TimeZone = utc) -> String {
    FileNaming.baseName(template: template, app: app, date: date, timeZone: timeZone)
}

equal("default template", name("Karuta {date} {time}"), "Karuta 2026-10-31 13.05.09")
equal("app", name("{app} {date}"), "Safari 2026-10-31")
equal("unknown app collapses the spaces", name("Karuta {app} {time}", app: nil), "Karuta 13.05.09")
equal("empty app collapses the spaces", name("{app}  {date}", app: ""), "2026-10-31")
equal("slash and colon can't be in a file name", name("a/b:c {app}", app: "Foo/Bar"), "a-b.c Foo-Bar")
equal("an empty result falls back to Karuta", name("{app}", app: nil), "Karuta")
equal("text without placeholders stays", name("Screenshot"), "Screenshot")
equal("the local time zone is used", name("{date} {time}", timeZone: TimeZone(identifier: "Asia/Tokyo")!),
      "2026-10-31 22.05.09")
equal("the next day in a time zone ahead of UTC",
      FileNaming.baseName(template: "{date}", app: nil, date: Date(timeIntervalSince1970: 1_793_491_200),
                          timeZone: TimeZone(identifier: "Asia/Tokyo")!), "2026-11-01")

let folder = URL(fileURLWithPath: "/tmp/karuta-check", isDirectory: true)
func unique(_ taken: Set<String>) -> String {
    FileNaming.uniqueURL(in: folder, base: "Karuta", extension: "png") { taken.contains($0.lastPathComponent) }
        .lastPathComponent
}
equal("a free name is used as is", unique([]), "Karuta.png")
equal("a taken name gets (2)", unique(["Karuta.png"]), "Karuta (2).png")
equal("(2) taken gets (3)", unique(["Karuta.png", "Karuta (2).png"]), "Karuta (3).png")
equal("the folder is kept",
      FileNaming.uniqueURL(in: folder, base: "x", extension: "jpg") { _ in false }.deletingLastPathComponent().path,
      "/tmp/karuta-check")

// Temp folders for drag & drop
let parent = FileManager.default.temporaryDirectory.appendingPathComponent("karuta-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: parent) }
let first = try! TempFolders.fresh(in: parent)
let second = try! TempFolders.fresh(in: parent)
check("each call gives a new empty folder", first != second
      && (try? FileManager.default.contentsOfDirectory(atPath: second.path))?.isEmpty == true)
let stale = parent.appendingPathComponent("stale", isDirectory: true)
try! FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 60 * 60)], ofItemAtPath: stale.path)
_ = try! TempFolders.fresh(in: parent)
check("folders older than an hour are removed", !FileManager.default.fileExists(atPath: stale.path))
check("recent folders stay", FileManager.default.fileExists(atPath: first.path))

print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
