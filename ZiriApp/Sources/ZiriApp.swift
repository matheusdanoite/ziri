import BackgroundTasks
import SwiftUI

@main
struct ZiriApp: App {
    @State private var sync = SyncManager()

    private let refreshTaskID = "fi.ziri.app.sync"

    var body: some Scene {
        WindowGroup {
            ContentView(sync: sync)
                .task { await sync.sync() }
        }
        .backgroundTask(.appRefresh(refreshTaskID)) {
            // Sync silencioso: sem UI, sem notificação. O sistema decide a hora,
            // normalmente quando o iPhone está na mesma Wi-Fi e ocioso.
            await sync.sync()
            await scheduleNext()
        }
    }

    private func scheduleNext() async {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
