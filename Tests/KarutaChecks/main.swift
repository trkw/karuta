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

// The GIF made from a recording (K18), pinned from ScreenRecorder.makeGIF before using KarutaCore for it.
// Its name: the old loop, written out here, and FileNaming.uniqueURL give the same file.
func oldGIFName(_ movie: URL, existing: Set<String>) -> String {
    let base = movie.deletingPathExtension()
    var gif = base.appendingPathExtension("gif")
    var n = 2
    while existing.contains(gif.path) {
        gif = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) (\(n)).gif")
        n += 1
    }
    return gif.path
}
let gifMovie = URL(fileURLWithPath: "/tmp/Recordings/Karuta 2026-11-13 21.40.12.mov")
for (label, existing) in [
    ("none", Set<String>()),
    ("the plain name", ["/tmp/Recordings/Karuta 2026-11-13 21.40.12.gif"]),
    ("the plain name and (2)", ["/tmp/Recordings/Karuta 2026-11-13 21.40.12.gif", "/tmp/Recordings/Karuta 2026-11-13 21.40.12 (2).gif"]),
    ("only (2)", ["/tmp/Recordings/Karuta 2026-11-13 21.40.12 (2).gif"]),
] {
    let base = gifMovie.deletingPathExtension()
    let new = FileNaming.uniqueURL(in: base.deletingLastPathComponent(), base: base.lastPathComponent, extension: "gif") {
        existing.contains($0.path)
    }
    equal("gif name: \(label) exists", new.path, oldGIFName(gifMovie, existing: existing))
}
// How many frames: 15 a second, at least 1, at most 120 seconds' worth.
func gifFrames(_ duration: Double) -> String { "\(GIFFrames.count(duration: duration))" }
equal("gif frames: 15 a second", gifFrames(1), "15")
equal("gif frames: a part frame is dropped", gifFrames(2.5), "37")
equal("gif frames: at least 1", gifFrames(0.05), "1")
equal("gif frames: an empty movie still has 1", gifFrames(0), "1")
equal("gif frames: 120 seconds", gifFrames(120), "1800")
equal("gif frames: longer movies stop at 120 seconds", gifFrames(500), "1800")
equal("gif frames: the rate", "\(GIFFrames.fps)", "15.0")

// The image formats (K5, part 1), pinned from Preferences.ImageFormat before moving it into KarutaCore.
// The raw values are what Settings stores, so they must not change.
equal("format: the raw values (stored in Settings)", ImageFormat.allCases.map(\.rawValue).joined(separator: ","), "png,jpeg,heic")
equal("format: menu order and titles", ImageFormat.allCases.map(\.title).joined(separator: ","), "PNG,JPEG,HEIC")
equal("format: file extensions", ImageFormat.allCases.map(\.fileExtension).joined(separator: ","), "png,jpg,heic")
equal("format: types", ImageFormat.allCases.map(\.utType.identifier).joined(separator: ","), "public.png,public.jpeg,public.heic")
equal("format: an unknown stored value is no format", "\(ImageFormat(rawValue: "jpg") == nil)", "true")

// The numbers used when a capture is written (K5, part 2), pinned from Exporter before moving them into
// KarutaCore. The image work itself stays in the app.
equal("export: 72 dpi at 1x", "\(ExportSettings.dpi(scale: 1))", "72.0")
equal("export: 144 dpi on Retina", "\(ExportSettings.dpi(scale: 2))", "144.0")
equal("export: lossy quality", "\(ExportSettings.lossyQuality)", "0.9")
equal("export: quality only for lossy formats", ImageFormat.allCases.map { "\(ExportSettings.usesQuality($0.utType))" }.joined(separator: ","), "false,true,true")
func oneX(_ width: Int, _ height: Int, scale: CGFloat, on: Bool = true) -> String {
    ExportSettings.oneXSize(width: width, height: height, scale: scale, scaleRetina: on).map { "\($0.width)x\($0.height)" } ?? "keep"
}
equal("export: Retina to 1x halves the pixels", oneX(1600, 1200, scale: 2), "800x600")
equal("export: odd pixels round to nearest", oneX(1601, 1199, scale: 2), "801x600")
equal("export: a 1.5 scale", oneX(300, 301, scale: 1.5), "200x201")
equal("export: off keeps the shot", oneX(1600, 1200, scale: 2, on: false), "keep")
equal("export: a 1x shot is kept", oneX(1600, 1200, scale: 1), "keep")
equal("export: a 1 pixel shot at 3x is kept (would be 0 wide)", oneX(1, 1, scale: 3), "keep")

// The shapes the editor draws (K19), pinned from CanvasView+Mouse before moving them into KarutaCore.
func shapeRect(_ a: CGPoint, _ b: CGPoint, square: Bool = false) -> String {
    let r = DrawGeometry.rect(from: a, to: b, square: square)
    return "\(r.minX),\(r.minY) \(r.width)x\(r.height)"
}
equal("shape: a drag down-right", shapeRect(CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)), "10.0,20.0 30.0x40.0")
equal("shape: any direction starts at the lower corner", shapeRect(CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20)), "10.0,20.0 30.0x40.0")
equal("shape: Shift makes a square on the longer side", shapeRect(CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 30), square: true), "10.0,20.0 30.0x30.0")
equal("shape: a square keeps the drag's direction", shapeRect(CGPoint(x: 40, y: 60), CGPoint(x: 30, y: 20), square: true), "0.0,20.0 40.0x40.0")
equal("shape: no drag is empty", shapeRect(CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), square: true), "5.0,5.0 0.0x0.0")
func snapped(_ p: CGPoint, from start: CGPoint = .zero) -> String {
    let q = DrawGeometry.snap(p, from: start)
    return String(format: "%.2f,%.2f", q.x, q.y)
}
equal("snap: nearly level becomes level, same length", snapped(CGPoint(x: 100, y: 10)), String(format: "%.2f,%.2f", hypot(Double(100), Double(10)), 0))
equal("snap: near 45° becomes 45°", snapped(CGPoint(x: 100, y: 90)), String(format: "%.2f,%.2f", hypot(Double(100), Double(90)) / 2.0.squareRoot(), hypot(Double(100), Double(90)) / 2.0.squareRoot()))
equal("snap: nearly upright becomes upright", snapped(CGPoint(x: -5, y: -100)), String(format: "%.2f,%.2f", 0.0, -hypot(Double(5), Double(100))))
equal("snap: measured from the start", snapped(CGPoint(x: 110, y: 52), from: CGPoint(x: 10, y: 50)), String(format: "%.2f,%.2f", 10 + hypot(Double(100), Double(2)), 50.0))

// Coordinate conversions (K20), pinned from Geometry.appKitRect and Capturer.sourceRect before moving
// them into KarutaCore. They feed the capture rect, so the math must not change.
func rectText(_ r: CGRect) -> String { "\(r.minX),\(r.minY) \(r.width)x\(r.height)" }
equal("coords: CG top-left to AppKit bottom-left",
      rectText(ScreenGeometry.appKitRect(fromCG: CGRect(x: 100, y: 50, width: 200, height: 100), primaryHeight: 1080)),
      "100.0,930.0 200.0x100.0")
equal("coords: a window on a screen above the main one",
      rectText(ScreenGeometry.appKitRect(fromCG: CGRect(x: 0, y: -500, width: 100, height: 100), primaryHeight: 1080)),
      "0.0,1480.0 100.0x100.0")
equal("coords: no screens means a height of 0",
      rectText(ScreenGeometry.appKitRect(fromCG: CGRect(x: 10, y: 20, width: 30, height: 40), primaryHeight: 0)),
      "10.0,-60.0 30.0x40.0")
equal("coords: source rect on the main screen",
      rectText(ScreenGeometry.sourceRect(CGRect(x: 100, y: 200, width: 300, height: 100), screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))),
      "100.0,600.0 300.0x100.0")
equal("coords: source rect on a screen to the right and lower",
      rectText(ScreenGeometry.sourceRect(CGRect(x: 1500, y: 0, width: 100, height: 100), screenFrame: CGRect(x: 1440, y: -200, width: 1920, height: 1080))),
      "60.0,780.0 100.0x100.0")
equal("coords: the whole screen is the source rect from 0",
      rectText(ScreenGeometry.sourceRect(CGRect(x: 1440, y: -200, width: 1920, height: 1080), screenFrame: CGRect(x: 1440, y: -200, width: 1920, height: 1080))),
      "0.0,0.0 1920.0x1080.0")

// Where a Quick Access card sits (K21), pinned from QuickOverlay.x(for:hidden:) before moving it into KarutaCore.
let cardScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
func cardX(onRight: Bool, hidden: Bool, gap: CGFloat = 20, screen: CGRect = cardScreen) -> String {
    "\(CardLayout.x(screenFrame: screen, cardWidth: 300, onRight: onRight, hidden: hidden, margin: 16, gap: gap))"
}
equal("card: left, shown, inside the margin", cardX(onRight: false, hidden: false), "16.0")
equal("card: left, hidden, past the edge and the gap", cardX(onRight: false, hidden: true), "-320.0")
equal("card: right, shown, inside the margin", cardX(onRight: true, hidden: false), "1124.0")
equal("card: right, hidden, past the edge and the gap", cardX(onRight: true, hidden: true), "1460.0")
equal("card: hidden with no gap (where it slides in from)", cardX(onRight: false, hidden: true, gap: 0), "-300.0")
equal("card: on a second screen to the right", cardX(onRight: true, hidden: false, screen: CGRect(x: 1440, y: 0, width: 1920, height: 1080)), "3044.0")

// The next counter number in the editor (K22), pinned from CanvasView.nextCounter before moving it into KarutaCore.
func nextCounter(_ existing: [Int], override: Int? = nil) -> String {
    "\(CounterNumbers.next(existing: existing, override: override))"
}
equal("counter: the first is 1", nextCounter([]), "1")
equal("counter: one past the highest", nextCounter([1, 2, 3]), "4")
equal("counter: gaps are not filled", nextCounter([1, 5]), "6")
equal("counter: order does not matter", nextCounter([3, 1, 2]), "4")
equal("counter: a number set by hand wins", nextCounter([1, 2], override: 10), "10")
equal("counter: a set number of 0 is kept", nextCounter([1, 2], override: 0), "0")
equal("counter: negative numbers count as none", nextCounter([-3]), "1")
equal("counter: setting a number below 0 keeps 0", "\(CounterNumbers.clamped(-5))", "0")
equal("counter: setting a number keeps it", "\(CounterNumbers.clamped(7))", "7")

// Stroke widths (K23), pinned from CanvasView.widthSteps and the 1–6 keys before moving them into KarutaCore.
equal("width: the six steps", StrokeWidth.steps.map { "\($0)" }.joined(separator: ","), "1.0,2.0,4.0,6.0,8.0,12.0")
equal("width: key 1 is the thinnest", "\(StrokeWidth.forKey("1") ?? -1)", "1.0")
equal("width: key 4", "\(StrokeWidth.forKey("4") ?? -1)", "6.0")
equal("width: key 6 is the thickest", "\(StrokeWidth.forKey("6") ?? -1)", "12.0")
equal("width: key 0 is not a width", "\(StrokeWidth.forKey("0") == nil)", "true")
equal("width: key 7 is not a width", "\(StrokeWidth.forKey("7") == nil)", "true")
equal("width: a letter is not a width", "\(StrokeWidth.forKey("a") == nil)", "true")
equal("width: two digits are not a width", "\(StrokeWidth.forKey("12") == nil)", "true")
equal("width: no key is not a width", "\(StrokeWidth.forKey("") == nil)", "true")

// Where a pin window opens (K24), pinned from PinWindow.init before moving it into KarutaCore:
// the capture's real size, shrunk to fit 80% of the visible screen, centred on the card, kept on screen.
let pinVisible = CGRect(x: 0, y: 0, width: 1440, height: 900)
func pinFrame(_ width: CGFloat, _ height: CGFloat, around card: CGRect, visible: CGRect = pinVisible) -> String {
    rectText(PinLayout.frame(pointSize: CGSize(width: width, height: height), around: card, visible: visible))
}
equal("pin: a small capture opens at its real size, centred on the card",
      pinFrame(200, 100, around: CGRect(x: 100, y: 100, width: 300, height: 200)), "150.0,150.0 200.0x100.0")
equal("pin: a wide capture shrinks to 80% of the screen's width",
      pinFrame(1600, 400, around: CGRect(x: 0, y: 0, width: 1000, height: 1000), visible: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
      "100.0,400.0 800.0x200.0")
equal("pin: a tall capture shrinks to 80% of the screen's height",
      pinFrame(500, 2000, around: CGRect(x: 0, y: 0, width: 1000, height: 1000), visible: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
      "400.0,100.0 200.0x800.0")
equal("pin: pushed back from the right edge",
      pinFrame(200, 100, around: CGRect(x: 1350, y: 400, width: 100, height: 100)), "1240.0,400.0 200.0x100.0")
equal("pin: pushed up from the bottom-left corner, above the Dock",
      pinFrame(200, 100, around: CGRect(x: 0, y: 0, width: 100, height: 20), visible: CGRect(x: 0, y: 25, width: 1440, height: 850)),
      "0.0,25.0 200.0x100.0")
equal("pin: on a screen to the left of the main one",
      pinFrame(400, 300, around: CGRect(x: -1010, y: 450, width: 100, height: 100), visible: CGRect(x: -1920, y: 0, width: 1920, height: 1055)),
      "-1160.0,350.0 400.0x300.0")

// A pin window's scroll rules (K25), pinned from PinWindow.scrollWheel before moving them into KarutaCore:
// a mouse wheel counts 8 times, scrolling zooms (width 60–4000, aspect kept, centre kept), ⌥ changes opacity (0.2–1).
func r1(_ r: CGRect) -> String { String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height) }
equal("pin scroll: a trackpad's delta is used as it is", "\(PinLayout.scrollDelta(3, precise: true))", "3.0")
equal("pin scroll: a mouse wheel's delta counts 8 times", "\(PinLayout.scrollDelta(3, precise: false))", "24.0")
equal("pin scroll: down on a wheel too", "\(PinLayout.scrollDelta(-1, precise: false))", "-8.0")
equal("pin opacity: a step of delta / 200", String(format: "%.2f", PinLayout.opacity(0.5, delta: -40)), "0.30")
equal("pin opacity: no more than 1", String(format: "%.2f", PinLayout.opacity(1, delta: 20)), "1.00")
equal("pin opacity: no less than 0.2", String(format: "%.2f", PinLayout.opacity(0.3, delta: -100)), "0.20")
let pinZoomFrame = CGRect(x: 100, y: 100, width: 200, height: 100)
equal("pin zoom: 1 + delta / 300 times wider, aspect and centre kept",
      r1(PinLayout.zoomed(pinZoomFrame, delta: 30, aspect: 0.5)), "90.0,95.0 220.0x110.0")
equal("pin zoom: no narrower than 60",
      r1(PinLayout.zoomed(CGRect(x: 0, y: 0, width: 61, height: 61), delta: -300, aspect: 1)), "0.5,0.5 60.0x60.0")
equal("pin zoom: no wider than 4000",
      r1(PinLayout.zoomed(CGRect(x: 0, y: 0, width: 3900, height: 1950), delta: 300, aspect: 0.5)), "-50.0,-25.0 4000.0x2000.0")

print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
