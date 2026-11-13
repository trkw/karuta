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
equal("an app name of spaces only falls back to Karuta", name("{app}", app: "   "), "Karuta")
equal("spaces around the result are trimmed", name(" {app} {date} ", app: nil), "2026-10-31")
equal("a colon in the app name becomes a dot", name("{app}", app: "Foo: Bar"), "Foo. Bar")
equal("the local time zone is used", name("{date} {time}", timeZone: TimeZone(identifier: "Asia/Tokyo")!),
      "2026-10-31 22.05.09")
equal("the next day in a time zone ahead of UTC",
      FileNaming.baseName(template: "{date}", app: nil, date: Date(timeIntervalSince1970: 1_793_491_200),
                          timeZone: TimeZone(identifier: "Asia/Tokyo")!), "2026-11-01")

// Pinned before reusing the formatters (refactoring K8): the same results when time zones alternate,
// when a placeholder repeats, and when called from many threads at once.
let tokyo = TimeZone(identifier: "Asia/Tokyo")!
let newYork = TimeZone(identifier: "America/New_York")!
equal("time zones alternate: UTC", name("{date} {time}"), "2026-10-31 13.05.09")
equal("time zones alternate: Tokyo", name("{date} {time}", timeZone: tokyo), "2026-10-31 22.05.09")
equal("time zones alternate: New York", name("{date} {time}", timeZone: newYork), "2026-10-31 09.05.09")
equal("time zones alternate: UTC again", name("{date} {time}"), "2026-10-31 13.05.09")
equal("a placeholder used twice", name("{date}_{date} {time}{time}"), "2026-10-31_2026-10-31 13.05.0913.05.09")
equal("midnight", FileNaming.baseName(template: "{date} {time}", app: nil,
                                      date: Date(timeIntervalSince1970: 1_793_491_200), timeZone: utc),
      "2026-11-01 00.00.00")
var concurrentResults = [String](repeating: "", count: 400)
let resultsLock = NSLock()
DispatchQueue.concurrentPerform(iterations: concurrentResults.count) { i in
    let zone = i % 2 == 0 ? utc : tokyo
    let result = FileNaming.baseName(template: "{date} {time}", app: nil, date: date, timeZone: zone)
    resultsLock.lock(); concurrentResults[i] = result; resultsLock.unlock()
}
check("many threads at once give the same names", concurrentResults.enumerated().allSatisfy { i, result in
    result == (i % 2 == 0 ? "2026-10-31 13.05.09" : "2026-10-31 22.05.09")
})

let folder = URL(fileURLWithPath: "/tmp/karuta-check", isDirectory: true)
func unique(_ taken: Set<String>) -> String {
    FileNaming.uniqueURL(in: folder, base: "Karuta", extension: "png") { taken.contains($0.lastPathComponent) }
        .lastPathComponent
}
equal("a free name is used as is", unique([]), "Karuta.png")
equal("a taken name gets (2)", unique(["Karuta.png"]), "Karuta (2).png")
equal("(2) taken gets (3)", unique(["Karuta.png", "Karuta (2).png"]), "Karuta (3).png")
equal("a gap in the numbers is filled", unique(["Karuta.png", "Karuta (3).png"]), "Karuta (2).png")
equal("many taken names", unique(Set(["Karuta.png"] + (2...10).map { "Karuta (\($0)).png" })), "Karuta (11).png")
equal("the folder is kept",
      FileNaming.uniqueURL(in: folder, base: "x", extension: "jpg") { _ in false }.deletingLastPathComponent().path,
      "/tmp/karuta-check")

// The Save As panel's 形式 menu: only an image extension is swapped, so dots in the name stay
func swapped(_ name: String, _ ext: String) -> String { FileNaming.replacingImageExtension(of: name, with: ext) }
equal("png to jpg", swapped("Karuta 2026-10-31 13.05.09.png", "jpg"), "Karuta 2026-10-31 13.05.09.jpg")
equal("jpg to heic", swapped("Karuta 2026-10-31 13.05.09.jpg", "heic"), "Karuta 2026-10-31 13.05.09.heic")
equal("heic to png", swapped("memo.heic", "png"), "memo.png")
equal("jpeg typed by hand", swapped("memo.jpeg", "png"), "memo.png")
equal("upper-case extension", swapped("memo.PNG", "jpg"), "memo.jpg")
equal("no extension keeps the time's dots", swapped("Karuta 2026-10-31 13.05.09", "jpg"), "Karuta 2026-10-31 13.05.09.jpg")
equal("a version number stays", swapped("design v1.2", "png"), "design v1.2.png")
equal("another extension stays", swapped("notes.txt", "png"), "notes.txt.png")
equal("only the last extension", swapped("a.png.png", "jpg"), "a.png.jpg")
equal("an empty name", swapped("", "png"), ".png")

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

// The one-hour rule, pinned at its edges (K3): 59 minutes stays, 61 minutes goes
let edge = FileManager.default.temporaryDirectory.appendingPathComponent("karuta-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: edge) }
let now = Date()
func aged(_ name: String, minutes: Double) -> URL {
    let url = edge.appendingPathComponent(name, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-minutes * 60)], ofItemAtPath: url.path)
    return url
}
let young = aged("young", minutes: 59)
let old = aged("old", minutes: 61)
let made = try! TempFolders.fresh(in: edge, now: now)
check("59 minutes old stays", FileManager.default.fileExists(atPath: young.path))
check("61 minutes old is removed", !FileManager.default.fileExists(atPath: old.path))
check("the new folder is inside the parent", made.deletingLastPathComponent().standardizedFileURL.path == edge.standardizedFileURL.path)

// Where the temp folders are (K3). The literal paths are the ones Exporter wrote inline before
let base = URL(fileURLWithPath: "/tmp/karuta-base", isDirectory: true)
equal("app folder name", TempFolders.folderName(bench: false), "Karuta")
equal("bench folder name", TempFolders.folderName(bench: true), "Karuta Bench")
equal("clipboard folder", TempFolders.directory(.clipboard, folderName: "Karuta", base: base).path, "/tmp/karuta-base/Karuta/Clipboard")
equal("drag folder", TempFolders.directory(.drag, folderName: "Karuta", base: base).path, "/tmp/karuta-base/Karuta/Drag")
equal("recordings folder", TempFolders.directory(.recordings, folderName: "Karuta", base: base).path, "/tmp/karuta-base/Karuta/Recordings")
equal("bench clipboard folder", TempFolders.directory(.clipboard, folderName: "Karuta Bench", base: base).path, "/tmp/karuta-base/Karuta Bench/Clipboard")
check("same URL as the old inline expression",
      TempFolders.directory(.drag, folderName: "Karuta Bench") == FileManager.default.temporaryDirectory.appendingPathComponent("Karuta Bench/Drag", isDirectory: true))

// UserDefaults keys (K7). The strings Preferences used before; a changed one would lose that setting
let storedKeys = [
    "showOverlay", "copyToClipboard", "copyAreaCaptureToClipboard", "saveToFile", "freezeScreen", "playSound",
    "openEditor", "showMenuBarIcon", "hideDesktopIcons", "showLoupe", "shutterSound", "overlayOnRight",
    "overlaySize", "autoCloseSeconds", "showCursor", "scaleRetina", "copyAsFile", "fileNameTemplate",
    "historyDays", "selfTimerSeconds", "selectionAspect", "fixedSelectionSize", "backdropStyle", "backdropGradient",
    "backdropColor", "recordingFormat", "recordingCountdown", "recordingFrameRate", "recordSystemAudio", "showClicks",
    "savedColors", "backdropImagePath", "autoBackdrop", "backdropPadding", "format", "saveDirectory",
]
equal("every key is listed", "\(PreferenceKey.allCases.count)", "\(storedKeys.count)")
for (key, stored) in zip(PreferenceKey.allCases, storedKeys) {
    equal("key \(stored)", key.rawValue, stored)
}
equal("editor style key", PreferenceKey.editorStyle("arrow"), "editorStyle.arrow")
equal("shortcut key", PreferenceKey.shortcut("area"), "shortcut.area")

// MARK: History (K13): what has expired, and where a capture goes in the newest-first list.

let historyNow = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86_400
check("history off: everything has expired", HistoryRules.isExpired(historyNow, days: 0, now: historyNow))
check("negative days: everything has expired", HistoryRules.isExpired(historyNow, days: -1, now: historyNow))
check("inside the period stays", !HistoryRules.isExpired(historyNow - 30 * day + 1, days: 30, now: historyNow))
check("exactly at the cutoff stays", !HistoryRules.isExpired(historyNow - 30 * day, days: 30, now: historyNow))
check("a second past the cutoff has expired", HistoryRules.isExpired(historyNow - 30 * day - 1, days: 30, now: historyNow))
check("one day keeps today", !HistoryRules.isExpired(historyNow - 3600, days: 1, now: historyNow))
let listed = [historyNow, historyNow - 10, historyNow - 20]  // newest first
equal("into an empty list", "\(HistoryRules.insertionIndex(for: historyNow, in: []))", "0")
equal("newer than all goes first", "\(HistoryRules.insertionIndex(for: historyNow + 5, in: listed))", "0")
equal("in between goes in its place", "\(HistoryRules.insertionIndex(for: historyNow - 15, in: listed))", "2")
equal("older than all goes last", "\(HistoryRules.insertionIndex(for: historyNow - 99, in: listed))", "3")
equal("the same time goes after the existing one", "\(HistoryRules.insertionIndex(for: historyNow - 10, in: listed))", "2")

// MARK: History index (K13): the JSON on users' Macs (Application Support/Karuta/History/index.json).

let storedIndex = #"""
[{"id":"A1","date":800000000.5,"kind":"area","width":640,"height":480,"scale":2,"app":"Safari"},
 {"id":"B2","date":799999000,"kind":"fullscreen","width":1,"height":1,"scale":1}]
"""#
let decodedIndex = try? JSONDecoder().decode([HistoryItem].self, from: Data(storedIndex.utf8))
check("index: the stored form reads", decodedIndex?.count == 2)
if let first = decodedIndex?.first, let second = decodedIndex?.last {
    check("index: date is seconds since 2001", first.date == Date(timeIntervalSinceReferenceDate: 800_000_000.5))
    check("index: fields", first.id == "A1" && first.kind == .area && first.width == 640 && first.height == 480)
    check("index: a whole-number scale reads as Double", first.scale == 2.0)
    check("index: app may be missing", second.app == nil && second.kind == .fullscreen)
}
equal("index: kind names", CaptureKind.allCases.map(\.rawValue).joined(separator: ","), "area,window,fullscreen")
// One entry with a kind Karuta does not know makes the whole index unreadable (today: history starts empty).
let unknownKind = #"[{"id":"C3","date":1,"kind":"scroll","width":1,"height":1,"scale":1}]"#
check("index: an unknown kind fails the whole index", (try? JSONDecoder().decode([HistoryItem].self, from: Data(unknownKind.utf8))) == nil)
// Written back with the same keys, and read back equal.
let item = HistoryItem(id: "D4", date: Date(timeIntervalSinceReferenceDate: 1234.5), kind: .window, width: 3, height: 4, scale: 2, app: nil)
if let data = try? JSONEncoder().encode([item]),
   let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
    equal("index: keys written", (object.first?.keys.sorted() ?? []).joined(separator: ","), "date,height,id,kind,scale,width")
    equal("index: date written as seconds since 2001", "\(object.first?["date"] ?? "")", "1234.5")
    check("index: round trip", (try? JSONDecoder().decode([HistoryItem].self, from: data)) == [item])
} else {
    check("index: encodes", false)
}

// MARK: History filter (K13): the history window's segments and what they show.

let byKind = [
    HistoryItem(id: "1", date: historyNow, kind: .area, width: 1, height: 1, scale: 1, app: nil),
    HistoryItem(id: "2", date: historyNow, kind: .window, width: 1, height: 1, scale: 1, app: nil),
    HistoryItem(id: "3", date: historyNow, kind: .area, width: 1, height: 1, scale: 1, app: nil),
]
equal("filter: all kinds", HistoryRules.items(byKind, ofKind: nil).map(\.id).joined(), "123")
equal("filter: one kind, in order", HistoryRules.items(byKind, ofKind: .area).map(\.id).joined(), "13")
equal("filter: a kind with nothing", HistoryRules.items(byKind, ofKind: .fullscreen).map(\.id).joined(), "")
equal("segment 0 is every kind", "\(String(describing: HistoryRules.kind(forSegment: 0)))", "nil")
equal("segments 1… follow the kinds", "\((1...3).map { HistoryRules.kind(forSegment: $0)?.rawValue ?? "nil" })", "[\"area\", \"window\", \"fullscreen\"]")

// MARK: Scrolling capture (K15): finding how far the stitchPage moved between two frames.

let stitchPage: [UInt64] = (0..<100).map { UInt64($0 + 1000) }
let stitchScrolled = Array(stitchPage[10...]) + (0..<10).map { UInt64($0 + 5000) }
equal("shift: a page scrolled by 10 rows", "\(StitchRows.shift(stitchPage, stitchScrolled, lo: 0, hi: 100).map(String.init) ?? "nil")", "10")
equal("shift: an unmoved, varied page is no shift", "\(StitchRows.shift(stitchPage, stitchPage, lo: 0, hi: 100).map(String.init) ?? "nil")", "nil")
let stitchPlain = [UInt64](repeating: 7, count: 100)
equal("shift: identical rows take the smallest shift", "\(StitchRows.shift(stitchPlain, stitchPlain, lo: 0, hi: 100).map(String.init) ?? "nil")", "1")
equal("shift: a span no wider than the minimum overlap", "\(StitchRows.shift(stitchPage, stitchScrolled, lo: 0, hi: 12).map(String.init) ?? "nil")", "nil")
var stitchMostly = stitchScrolled
for i in stride(from: 0, to: 90, by: 12) { stitchMostly[i] = 9999 }  // 8 of 90 rows differ: 91% match
equal("shift: 91% of the overlap is enough", "\(StitchRows.shift(stitchPage, stitchMostly, lo: 0, hi: 100).map(String.init) ?? "nil")", "10")
var stitchHalf = stitchScrolled
for i in stride(from: 0, to: 90, by: 5) { stitchHalf[i] = 9999 }  // 18 of 90 differ: 80%
equal("shift: 80% is not", "\(StitchRows.shift(stitchPage, stitchHalf, lo: 0, hi: 100).map(String.init) ?? "nil")", "nil")
equal("shift: within lo..<hi only", "\(StitchRows.shift([0, 0] + stitchPage, [9, 9] + stitchScrolled, lo: 2, hi: 102).map(String.init) ?? "nil")", "10")
func stitchContinuing(lo: Int, hi: Int) -> String {
    StitchRows.continuingShift(stitchPage, stitchScrolled, lo: lo, hi: hi).map(String.init) ?? "nil"
}
equal("continuing: 23 moving rows are too few", stitchContinuing(lo: 0, hi: 23), "nil")
equal("continuing: though shift alone finds one there", "\(StitchRows.shift(stitchPage, stitchScrolled, lo: 0, hi: 23) ?? -1)", "10")
equal("continuing: 24 moving rows are enough", stitchContinuing(lo: 0, hi: 24), "10")
equal("continuing: the span is hi - lo", stitchContinuing(lo: 10, hi: 33), "nil")
equal("continuing: the minimum span", "\(StitchRows.minimumSpan)", "24")
equal("continuing: no match is nil", StitchRows.continuingShift(stitchPage, stitchPage, lo: 0, hi: 100).map(String.init) ?? "nil", "nil")

func stitchFrames(width: Int, height: Int, changing columns: [Int]) -> ([UInt32], [UInt32]) {
    let old = [UInt32](repeating: 1, count: width * height)
    var new = old
    for y in 0..<height { for x in columns { new[y * width + x] = 2 } }
    return (old, new)
}
func stitchMoving(_ width: Int, _ columns: [Int]) -> String {
    let (old, new) = stitchFrames(width: width, height: 3, changing: columns)
    return StitchRows.movingColumns(old, new, width: width, height: 3).map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "nil"
}
equal("columns: nothing moved", stitchMoving(100, []), "nil")
equal("columns: from the first to the last change", stitchMoving(100, [5, 10]), "5..<11")
equal("columns: only the scroll bar changed", stitchMoving(100, [80, 99]), "nil")
equal("columns: the scroll bar is left out", stitchMoving(100, [50, 90]), "50..<76")
equal("columns: a narrow area is matched whole", stitchMoving(20, [19]), "19..<20")
equal("scroll bar width", "\(StitchRows.scrollBarWidth)", "24")

let stitchRow: [UInt32] = [0x0011_2233, 0x0044_5566, 0x0077_8899, 0x00aa_bbcc]
func stitchHash(_ row: [UInt32], _ columns: Range<Int> = 0..<4) -> UInt64 { StitchRows.rowHashes(row, width: 4, columns: columns)[0] }
check("hashes: the same row, the same hash", stitchHash(stitchRow) == stitchHash(stitchRow))
check("hashes: the alpha byte is ignored", stitchHash(stitchRow) == stitchHash(stitchRow.map { $0 | 0xff00_0000 }))
check("hashes: every other pixel (an odd column is skipped)", stitchHash(stitchRow) == stitchHash([stitchRow[0], 0, stitchRow[2], 0]))
check("hashes: an even column counts", stitchHash(stitchRow) != stitchHash([0, stitchRow[1], stitchRow[2], stitchRow[3]]))
check("hashes: columns outside the range are ignored", stitchHash(stitchRow, 2..<4) == stitchHash([9, 9, stitchRow[2], stitchRow[3]], 2..<4))
equal("hashes: one per row", "\(StitchRows.rowHashes(stitchRow + stitchRow, width: 4, columns: 0..<4).count)", "2")

// MARK: Scrolling capture (K15): the bands that did not move (sticky headers, toolbars, footers).

func stitchBands(_ old: [UInt64], _ new: [UInt64]) -> String {
    let bands = StitchRows.unmovedBands(old, new)
    return "\(bands.top),\(bands.bottom)"
}
equal("bands: nothing still", stitchBands([1, 2, 3, 4], [5, 6, 7, 8]), "0,0")
equal("bands: a sticky header", stitchBands([9, 2, 3, 4], [9, 6, 7, 8]), "1,0")
equal("bands: a fixed footer", stitchBands([1, 2, 3, 9], [5, 6, 7, 9]), "0,1")
equal("bands: both", stitchBands([9, 9, 3, 4, 8], [9, 9, 5, 6, 8]), "2,1")
equal("bands: the top band is counted first when all rows are equal", stitchBands([1, 2, 3], [1, 2, 3]), "3,0")
equal("bands: a middle equal row is not a band", stitchBands([1, 7, 3], [4, 7, 6]), "0,0")
equal("bands: no rows", stitchBands([], []), "0,0")

func stitchNext(keptEnd: Int, lo: Int, hi: Int, shift: Int, hasKept: Bool = true) -> String {
    let next = StitchRows.continuation(keptEnd: keptEnd, lo: lo, hi: hi, shift: shift, hasKept: hasKept)
    return "\(next.trim),\(next.start)"
}
equal("next: rows past the overlap are added", stitchNext(keptEnd: 100, lo: 0, hi: 100, shift: 30), "0,70")
equal("next: never above the sticky header", stitchNext(keptEnd: 100, lo: 20, hi: 100, shift: 90), "0,20")
equal("next: kept rows past a new footer come off", stitchNext(keptEnd: 100, lo: 0, hi: 90, shift: 30), "10,60")
equal("next: nothing comes off when nothing is kept", stitchNext(keptEnd: 100, lo: 0, hi: 90, shift: 30, hasKept: false), "0,70")
equal("next: kept end before the bottom band", stitchNext(keptEnd: 80, lo: 0, hi: 90, shift: 30), "0,50")
equal("next: a start at or past hi adds nothing", stitchNext(keptEnd: 100, lo: 0, hi: 100, shift: 0), "0,100")

// The recording's pixel size (K16), pinned from ScreenRecorder.outputSize before moving it into KarutaCore.
func recordingSize(_ width: CGFloat, _ height: CGFloat, scale: CGFloat) -> String {
    let size = RecordingSize.output(points: CGSize(width: width, height: height), scale: scale)
    return "\(size.width)x\(size.height)"
}
equal("recording: points times the scale", recordingSize(800, 600, scale: 2), "1600x1200")
equal("recording: odd sides round down to even", recordingSize(801, 601, scale: 1), "800x600")
equal("recording: a 5K screen fits 4096 x 2304", recordingSize(2560, 1440, scale: 2), "4096x2304")
equal("recording: a tall area fits the height, keeping the shape", recordingSize(1000, 3000, scale: 1), "768x2304")
equal("recording: a wide area fits the width", recordingSize(6000, 100, scale: 1), "4096x68")
equal("recording: fractions are dropped", recordingSize(100.7, 50.3, scale: 1), "100x50")
equal("recording: a 1.5 scale", recordingSize(333, 333, scale: 1.5), "498x498")
equal("recording: at least 2 x 2", recordingSize(1, 1, scale: 1), "2x2")
equal("recording: an empty area is 2 x 2", recordingSize(0, 0, scale: 2), "2x2")

// What a right click in the history window acts on (K17), pinned from HistoryWindow.items(around:)
// before moving it into HistoryRules.
func historyTargets(_ index: Int, selected: [Int], count: Int) -> String {
    HistoryRules.targets(around: index, selected: selected, count: count).map(String.init).joined(separator: ",")
}
equal("targets: no selection is the clicked item", historyTargets(2, selected: [], count: 5), "2")
equal("targets: inside the selection is the whole selection", historyTargets(1, selected: [3, 1], count: 5), "1,3")
equal("targets: outside the selection is the clicked item only", historyTargets(4, selected: [1, 3], count: 5), "4")
equal("targets: the selection is sorted", historyTargets(0, selected: [4, 0, 2], count: 5), "0,2,4")
equal("targets: indices past the shown items are dropped", historyTargets(1, selected: [1, 7], count: 5), "1")
equal("targets: a click past the end is nothing", historyTargets(5, selected: [], count: 5), "")
equal("targets: nothing shown", historyTargets(0, selected: [0], count: 0), "")

print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
