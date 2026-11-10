import Foundation
import KarutaCore

/// The bench copy made by scripts/make-bench-copy.sh (bundle ID com.trkw.karuta.bench), for checks and agents.
/// It runs next to the real Karuta without touching it: no global shortcuts, its own folders, and no
/// Screen Recording prompt at launch. The real app (com.trkw.karuta) is unaffected by any of this.
enum Bench {
    static let bundleID = "com.trkw.karuta.bench"
    static let isActive = Bundle.main.bundleIdentifier == bundleID
    /// The folder name under Application Support, Caches and the temp folder.
    static let folderName = TempFolders.folderName(bench: isActive)
}
