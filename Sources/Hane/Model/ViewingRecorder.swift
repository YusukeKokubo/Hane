import AppKit
import Observation

/// 利用者がこのアプリの画面を見ていそうか。アプリが前にいて、画面が眠っておらず、ロックされていないこと。
///
/// 閲覧履歴の「見ていた時間」を数えるのに使う。知らせを受けて変えるだけで、タイマーは使わない。
@MainActor
@Observable
final class ViewerPresence {
    static let shared = ViewerPresence()

    private(set) var isActive = NSApplication.shared.isActive
    private var screenAwake = true
    private var unlocked = true

    var isPresent: Bool { isActive && screenAwake && unlocked }

    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []

    private init() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        tokens = [
            listen(app, NSApplication.didBecomeActiveNotification) { $0.isActive = true },
            listen(app, NSApplication.didResignActiveNotification) { $0.isActive = false },
            listen(workspace, NSWorkspace.screensDidWakeNotification) { $0.screenAwake = true },
            listen(workspace, NSWorkspace.screensDidSleepNotification) { $0.screenAwake = false },
            listen(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.unlocked = true },
            listen(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.unlocked = false },
            listen(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.unlocked = true },
            listen(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.unlocked = false },
        ]
    }

    private func listen(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ change: @escaping @MainActor (ViewerPresence) -> Void
    ) -> any NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
            }
        }
    }
}

/// 今見ているページが変わったら閲覧履歴へ伝え、ページごとに見ていた時間を数えさせる。
///
/// 見張るのは、窓が前にいるか、選んでいるタブ、そのページのアドレス。変わったときにだけ動き、タイマーは使わない。
@MainActor
final class ViewingRecorder {
    private let history: HistoryStore
    private let viewed: () -> URL?
    private var stopped = false

    /// `viewed` は今見ているページのアドレス。何も見ていなければ `nil`。
    init(history: HistoryStore, viewed: @escaping () -> URL?) {
        self.history = history
        self.viewed = viewed
        watch()
    }

    func stop() {
        stopped = true
        history.view(nil)
    }

    private func watch() {
        let url = withObservationTracking {
            viewed()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.watch()
            }
        }
        history.view(url)
    }
}
