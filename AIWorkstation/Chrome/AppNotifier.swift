import SwiftUI
import UserNotifications

/// Lightweight dual notification surface (UI/UX spec → Notifications): an in-app
/// toast stack plus a best-effort macOS local notification, so agents running
/// across many cards/canvases can tell you when something needs attention even
/// when you aren't watching that terminal.
@MainActor
final class AppNotifier: ObservableObject {

    enum Kind {
        case info, success, error
        var icon: String {
            switch self {
            case .info:    return "bell.fill"
            case .success: return "checkmark.circle.fill"
            case .error:   return "exclamationmark.triangle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .info:    return Color(red: 0.45, green: 0.62, blue: 1.0)
            case .success: return Color(red: 0.36, green: 0.80, blue: 0.52)
            case .error:   return Color(red: 0.95, green: 0.42, blue: 0.42)
            }
        }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String?
        let kind: Kind
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    @Published private(set) var toasts: [Toast] = []

    /// Master switch (Settings → Behavior). Off → no toasts, no OS notifications.
    var enabled = true
    private var didRequestAuth = false

    /// Post an in-app toast and (best-effort) a macOS local notification.
    /// `system: false` skips the OS notification for low-signal events.
    func post(_ title: String, body: String? = nil, kind: Kind = .info, system: Bool = true) {
        guard enabled else { return }
        let toast = Toast(title: title, body: body, kind: kind)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            toasts.append(toast)
            // Cap the visible stack so a burst can't bury the canvas.
            if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        }
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.dismiss(id)
        }
        if system { postSystem(title: title, body: body, kind: kind) }
    }

    func dismiss(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toasts.removeAll { $0.id == id }
        }
    }

    // MARK: macOS local notification (best-effort)

    private func postSystem(title: String, body: String?, kind: Kind) {
        let center = UNUserNotificationCenter.current()
        requestAuthIfNeeded(center)
        let content = UNMutableNotificationContent()
        content.title = title
        if let body, !body.isEmpty { content.body = body }
        content.sound = (kind == .error) ? .default : nil
        // Immediate delivery (nil trigger). Unique id so identical messages stack.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private func requestAuthIfNeeded(_ center: UNUserNotificationCenter) {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
