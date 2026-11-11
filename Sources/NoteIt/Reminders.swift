import AppKit
import SwiftUI
import UserNotifications

/// Schedules one macOS notification per note reminder and opens the note when it fires.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Reminders()

  /// Shows a note: its sticky if pinned, otherwise All Notes. Set by the app delegate.
  var reveal: (UUID) -> Void = { _ in }
  private var scheduled: [UUID: Date] = [:]
  private var asked = false
  private let store = NoteStore.shared

  func start() {
    UNUserNotificationCenter.current().delegate = self
    NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .notesChanged, object: store)
    sync()
  }

  /// Matches pending notifications to the notes' reminders.
  @objc func sync() {
    let now = Date()
    var want: [UUID: (Date, String)] = [:]
    for n in store.notes where n.trashed == nil {
      if let r = n.remind, r > now { want[n.id] = (r, n.title) }
    }
    let center = UNUserNotificationCenter.current()
    let gone = scheduled.keys.filter { want[$0] == nil }
    if !gone.isEmpty {
      center.removePendingNotificationRequests(withIdentifiers: gone.map(\.uuidString))
      gone.forEach { scheduled.removeValue(forKey: $0) }
    }
    let new = want.filter { scheduled[$0.key] != $0.value.0 }
    guard !new.isEmpty else { return }
    if !asked {
      asked = true
      center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    for (id, (date, title)) in new {
      let c = UNMutableNotificationContent()
      c.title = title
      c.body = "Reminder from NoteIt"
      c.sound = .default
      c.userInfo = ["id": id.uuidString]
      let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
      let req = UNNotificationRequest(identifier: id.uuidString, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
      center.add(req)
      scheduled[id] = date
    }
  }

  private func fired(_ idString: String, open: Bool) {
    guard let id = UUID(uuidString: idString), var n = store.note(id) else { return }
    n.remind = nil
    store.update(n)
    if open { reveal(id) }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    let id = notification.request.identifier
    await MainActor.run { self.fired(id, open: true) }
    return [.banner, .sound]
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let id = response.notification.request.identifier
    await MainActor.run {
      NSApp.activate()
      self.fired(id, open: true)
    }
  }
}

/// Pick a reminder time: quick choices, or any date and time.
struct ReminderPicker: View {
  let current: Date?
  let onSet: (Date?) -> Void
  @State private var date: Date

  init(current: Date?, onSet: @escaping (Date?) -> Void) {
    self.current = current
    self.onSet = onSet
    _date = State(initialValue: current ?? Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date())
  }

  private static func at(_ hour: Int, daysFromNow: Int) -> Date {
    let cal = Calendar.current
    let day = cal.date(byAdding: .day, value: daysFromNow, to: Date()) ?? Date()
    return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
  }

  private var quick: [(String, Date)] {
    var q: [(String, Date)] = [("In 1 Hour", Date().addingTimeInterval(3600))]
    let evening = Self.at(18, daysFromNow: 0)
    if evening > Date().addingTimeInterval(600) { q.append(("This Evening", evening)) }
    q.append(("Tomorrow Morning", Self.at(9, daysFromNow: 1)))
    let cal = Calendar.current
    let toMonday = (9 - cal.component(.weekday, from: Date())) % 7
    q.append(("Next Week", Self.at(9, daysFromNow: toMonday == 0 ? 7 : toMonday)))
    return q
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Remind Me", systemImage: "bell").font(.headline)
      ForEach(quick, id: \.0) { title, d in
        Button {
          onSet(d)
        } label: {
          HStack {
            Text(title)
            Spacer()
            Text(d.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Divider()
      DatePicker("At", selection: $date, in: Date()...)
        .datePickerStyle(.compact)
      HStack {
        if current != nil {
          Button("Clear", role: .destructive) { onSet(nil) }
        }
        Spacer()
        Button("Set Reminder") { onSet(date) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(14)
    .frame(width: 300)
  }
}
