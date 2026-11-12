import AppKit
import SwiftUI

/// タブバーの空いた所。ここを掴んだときだけ窓を動かす。
///
/// 裏にいる窓でも、掴んだ一度目で動かせるよう、窓を前に出す事象も受ける。
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents()
    }
}

/// 置かれた窓を、AppKit が勝手に動かさないようにする。
///
/// タブバーはタイトルバーの位置にあり、AppKit はその一帯を掴むと窓を動かすので、
/// バーのタブやブックマークを引きずってもドラッグが始まらず窓が動いてしまう。
/// 窓の移動は `WindowDragArea` だけに任せる。
struct StillWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            window.isMovable = false
            // 動かせない窓は、画面を外したときもシステムが寄せてくれず、見えない所に取り残される。
            NotificationCenter.default.addObserver(
                self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
        }

        @objc private func screensChanged() {
            guard let window,
                  let frame = StillWindow.frame(window.frame, keptOn: NSScreen.screens.map(\.visibleFrame))
            else { return }
            window.setFrame(frame, display: true)
        }
    }

    /// 窓の上端の帯（掴む所）がどの画面にも見えていなければ、最初の画面の中へ収めた枠を返す。
    /// 見えていれば手を出さない（持ち主が自分で半分外へ出した窓まで戻さない）。
    nonisolated static func frame(_ frame: NSRect, keptOn screens: [NSRect]) -> NSRect? {
        let grip = NSRect(x: frame.minX, y: frame.maxY - 32, width: frame.width, height: 32)
        guard let target = screens.first, !screens.contains(where: { $0.intersects(grip) }) else { return nil }
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        return NSRect(
            x: min(max(frame.minX, target.minX), target.maxX - width),
            y: min(max(frame.minY, target.minY), target.maxY - height),
            width: width, height: height
        )
    }
}
