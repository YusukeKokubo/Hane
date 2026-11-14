import Foundation

/// テストのプロセスの主スレッドを、止められても回り続ける run loop の中に置く。
///
/// テストのプロセスの主スレッドは、Swift の非同期の入口が回す素の `CFRunLoopRun` で、これが返るとプロセスが
/// 終了コード 0 で黙って終わる。AppKit がイベントを待っている間（メニューを出して回している間など）に
/// ウインドウサーバーからイベントが届くと、HIToolbox が主スレッドを起こすために `CFRunLoopStop` を呼ぶ
/// ブロックを積む。そのブロックが走る前にメニューが閉じると、止める先が外側の素の `CFRunLoopRun` になる。
/// アプリでは `NSApplication.run` がまた回し直すので害がない。テストでもそれと同じく、止められたら回し直す。
@MainActor
enum MainRunLoop {
    static func keepRunning() {
        _ = started
    }

    private static let started: Void = {
        // 主キューのブロックの中で回すと、その間は主キュー（MainActor の仕事）が進まなくなるので、run loop のブロックで回す。
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            while true {
                CFRunLoopRun()
            }
        }
        CFRunLoopWakeUp(main)
    }()
}
