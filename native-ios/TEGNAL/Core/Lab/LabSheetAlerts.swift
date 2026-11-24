import BackgroundTasks
import Foundation
import UserNotifications

/// Tells the learner when a new cheat-sheet edition is published, if they asked for it at the foot of the sheet.
///
/// There is no push server: while the switch is on, iOS wakes the app now and then (`BGAppRefreshTask`, about twice a day at
/// most), it fetches the signed edition (`LabSheetSource.fetch`, which also keeps it for the sheet), and an edition dated
/// after the newest one the app already knew becomes one local notification. A tap opens the lab on the cheat sheet.
enum LabSheetAlerts {
    static let task = "work.nextline.tegnal.cheatsheet"
    static let onKey = "lab.sheet.alerts"
    /// The newest edition date (`yyyy-MM-dd`) already told or already on the device, so each edition is told once.
    static let knownKey = "lab.sheet.alerts.known"
    static let category = "lab.sheet"
    /// How long iOS is asked to wait before the next check. It may wait longer; it never comes sooner.
    static let interval: TimeInterval = 8 * 60 * 60

    private static var defaults: UserDefaults { ReaderPreferences.booruDefaults }

    static var isOn: Bool { defaults.bool(forKey: onKey) }

    /// Turns alerts on or off. Turning on asks for permission to notify; false comes back when it was refused.
    @discardableResult
    static func set(_ on: Bool) async -> Bool {
        guard on else {
            defaults.set(false, forKey: onKey)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: task)
            return true
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { defaults.set(false, forKey: onKey); return false }
        defaults.set(true, forKey: onKey)
        // What is on the device now is already known: only a later edition is news.
        remember(LabEdition.newest()?.date)
        schedule()
        return true
    }

    /// Whether iOS still lets the app notify. The learner can take it back in Settings while the switch stays on.
    static func allowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Asks iOS for the next background check. Called when the switch is turned on, when the app goes to the background,
    /// and at the end of each check.
    static func schedule() {
        guard isOn else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--lab-") || $0.contains("ui-test") }) { return }
        #endif
        let request = BGAppRefreshTaskRequest(identifier: task)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One background check: fetch the published edition and tell about it when it is newer than anything known.
    static func check() async {
        schedule()
        guard isOn else { return }
        let known = max(defaults.string(forKey: knownKey) ?? "", LabEdition.newest()?.date ?? "")
        guard let edition = await LabSheetSource.fetch(), news(edition, known: known), await allowed() else { return }
        remember(edition.date)
        await post(edition)
    }

    /// An edition is news when it is dated after the newest one known. A same-day correction is not.
    static func news(_ edition: LabEdition, known: String) -> Bool { edition.date > known }

    static func remember(_ date: String?) {
        guard let date, date > (defaults.string(forKey: knownKey) ?? "") else { return }
        defaults.set(date, forKey: knownKey)
    }

    static func post(_ edition: LabEdition) async {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("lab.sheet.alert.title")
        content.body = L10n.text("lab.sheet.alert.body", edition.stamp)
        content.sound = .default
        content.threadIdentifier = category
        content.userInfo = ["open": category]
        let request = UNNotificationRequest(identifier: "\(category).\(edition.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Shows a cheat-sheet alert while the app is open too, and opens the lab on the sheet when one is tapped.
final class LabSheetAlertDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LabSheetAlertDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["open"] as? String == LabSheetAlerts.category else { return }
        await MainActor.run { StudyMode.shared.enterLab(.sheet) }
    }
}
