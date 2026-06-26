import MurmurKit
import SwiftUI

/// Step 3 — Download (design: MurMur Onboarding.dc.html STEP 3). Two model cards
/// (Fast / Accurate) with live progress bars bound to `flow.fastFraction` /
/// `accurateFraction`, a derived "{downloaded} / {total} · {eta} · {speed}" line,
/// a done banner when both reach 100 %, and an error note with Retry. The actual
/// download runs from `OnboardingModel.startDownload`, triggered by this screen's
/// `.onAppear` — nothing downloads until the user reaches this step. Continue is
/// gated by the footer (`OnboardingFlow.canContinue` → both ≥ 1). Sizes/maths come
/// from `OnboardingFlow` — no hardcoded GB in the view.
struct DownloadScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    /// Tracks the previous (downloadedGB, timestamp) to derive speed + ETA from
    /// the fraction deltas — no separate byte accounting (GB is the SSOT here).
    @State private var lastGB = 0.0
    @State private var lastTick = Date()
    @State private var speedGBs = 0.0   // GB/second, smoothed

    private var t: OnTheme { OnTheme(scheme) }

    private var metrics: OnboardingFlow.DownloadMetrics {
        OnboardingFlow.downloadMetrics(fast: model.flow.fastFraction,
                                       accurate: model.flow.accurateFraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Download")
                    .font(.system(size: 11, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Mur.accent)
                Text("Getting my voice ready")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundStyle(t.ink).padding(.top, 10)
                Text("Two models download once, then run entirely on your Mac. A fast one for the instant draft, an accurate one to sharpen it.")
                    .font(.system(size: 14.5)).lineSpacing(4)
                    .foregroundStyle(t.muted(0.66))
                    .frame(maxWidth: 444, alignment: .leading).padding(.top, 11)
            }

            VStack(spacing: 12) {
                modelCard(title: "Fast model",
                          subtitle: "Instant draft as you speak",
                          sizeGB: OnboardingFlow.fastGB,
                          fraction: model.flow.fastFraction)
                modelCard(title: "Accurate model",
                          subtitle: "Sharpens every word a blink later",
                          sizeGB: OnboardingFlow.accurateGB,
                          fraction: model.flow.accurateFraction)
            }
            .padding(.top, 22)

            metricsLine.padding(.top, 14)

            if metrics.done {
                doneBanner.padding(.top, 14)
            } else if let err = model.downloadError {
                errorBanner(err).padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: metrics.downloadedGB) { _, newGB in updateSpeed(newGB) }
        .onAppear { model.startDownload() }   // download starts when this step is reached
    }

    // MARK: - Per-model card

    private func modelCard(title: LocalizedStringKey,
                           subtitle: LocalizedStringKey,
                           sizeGB: Double,
                           fraction: Double) -> some View {
        let ready = fraction >= 1
        let pct = Int((fraction * 100).rounded())
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(t.ink)
                        Text(verbatim: String(format: "%.1f GB", sizeGB))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(t.muted(0.55))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(t.line(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(t.muted(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if ready {
                    readyPill
                } else {
                    Text(verbatim: "\(pct)%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Mur.accent)
                }
            }

            progressBar(fraction: fraction, ready: ready)
        }
        .padding(16)
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private func progressBar(fraction: Double, ready: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.line(0.1))
                Capsule().fill(ready ? AnyShapeStyle(t.ok) : AnyShapeStyle(Mur.accent))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 7)
    }

    private var readyPill: some View {
        HStack(spacing: 6) {
            Text(verbatim: "✓").font(.system(size: 12, weight: .bold))
            Text("Ready").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(t.ok)
        .padding(.horizontal, 13).padding(.vertical, 6)
        .background(t.ok.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Metrics line ("{downloaded} / {total} · {eta} · {speed}")

    private var metricsLine: some View {
        let m = metrics
        let downloaded = String(format: "%.1f", m.downloadedGB)
        let total = String(format: "%.1f", m.totalGB)
        return HStack(spacing: 0) {
            Text(verbatim: "\(downloaded) / \(total) GB")
            if !m.done {
                Text(verbatim: " · ")
                Text(verbatim: etaText(remainingGB: m.remainingGB))
                Text(verbatim: " · ")
                Text(verbatim: speedText)
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundStyle(t.muted(0.5))
    }

    /// Human ETA from the remaining GB and the smoothed speed. Falls back to a
    /// neutral placeholder until a speed sample exists.
    private func etaText(remainingGB: Double) -> String {
        guard speedGBs > 0.0001 else { return "estimating…" }
        let secs = Int((remainingGB / speedGBs).rounded())
        if secs >= 60 { return "~\(secs / 60)m \(secs % 60)s left" }
        return "~\(secs)s left"
    }

    private var speedText: String {
        guard speedGBs > 0.0001 else { return "—" }
        let mbs = speedGBs * 1024   // GB/s → MB/s
        return String(format: "%.0f MB/s", mbs)
    }

    /// Derive instantaneous speed from the GB delta since the last tick, lightly
    /// smoothed (EMA) so the line doesn't jitter.
    private func updateSpeed(_ newGB: Double) {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        let dGB = newGB - lastGB
        if dt > 0.05, dGB > 0 {
            let sample = dGB / dt
            speedGBs = speedGBs == 0 ? sample : speedGBs * 0.6 + sample * 0.4
            lastGB = newGB
            lastTick = now
        } else if dGB > 0 {
            lastGB = newGB
        }
    }

    // MARK: - Done / error banners

    private var doneBanner: some View {
        HStack(spacing: 11) {
            Circle().fill(t.ok).frame(width: 22, height: 22)
                .overlay(Text(verbatim: "✓").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            Text("Both models are on your Mac — you’re ready to roll.")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(t.ink)
            Spacer(minLength: 0)
        }
        .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(t.ok.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(t.ok.opacity(0.3), lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The download hit a snag.")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Mur.error)
                Text(verbatim: message)
                    .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(t.muted(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { model.retryDownload() } label: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Mur.error)
                    .padding(.horizontal, 17).padding(.vertical, 9)
                    .background(Mur.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Mur.error, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(Mur.error.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Mur.error.opacity(0.3), lineWidth: 1))
    }
}
