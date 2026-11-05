import SwiftUI

/// 显示当前一次性验证码周期的剩余时间。
struct OTPCountdownRing: View {
    private static let diameter: CGFloat = 18
    private static let lineWidth: CGFloat = 2.5
    private static let updateInterval: TimeInterval = 1

    let period: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.updateInterval)) { context in
            let periodDuration = TimeInterval(max(period, 1))
            let elapsed = context.date.timeIntervalSince1970
                .truncatingRemainder(dividingBy: periodDuration)
            let remaining = periodDuration - elapsed
            let progress = min(max(remaining / periodDuration, 0), 1)
            let tint = remaining < 5 ? Color.red : Color.green

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
        }
    }
}
