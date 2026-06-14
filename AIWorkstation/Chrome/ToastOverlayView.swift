import SwiftUI

/// Top-right stack of transient in-app toasts (driven by `AppNotifier`). Glass
/// capsules that slide in from the trailing edge and auto-dismiss; click to close.
struct ToastOverlayView: View {
    @ObservedObject var notifier: AppNotifier

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(notifier.toasts) { toast in
                toastRow(toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, 56)        // clears the floating toolbar pill
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(true)
    }

    private func toastRow(_ toast: AppNotifier.Toast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.kind.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let body = toast.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }

            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow, blending: .behindWindow)
                Theme.chromeFill
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(toast.kind.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: 16, y: 7)
        .contentShape(Rectangle())
        .onTapGesture { notifier.dismiss(toast.id) }
    }
}
