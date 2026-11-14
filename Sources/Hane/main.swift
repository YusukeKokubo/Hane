import AppKit

// 入口。メニューと窓を AppKit で組むので、SwiftUI の App は使わない。
// delegate は NSApplication が弱く持つので、走っている間ここで掴んでおく。
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
