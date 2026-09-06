import Foundation

/// Burn-rate estimator ported from CodexBar's `UsagePace` engine.
///
/// Compares actual burn (`usedPercent`) against linear expectation
/// (`elapsed / duration`) for a limit window, yielding the deficit/reserve
/// language CodexBar shows: "N% in deficit" (ahead of pace) vs
/// "N% in reserve" (behind pace, i.e. headroom), plus a projected
/// exhaustion time or a lasts-until-reset verdict.
///
/// Pure math, no provider knowledge. `windowMinutes` + `resetsAt` define the
/// window; without both there is no pace to compute.
struct UsagePace: Equatable {
    enum Stage: Equatable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    let stage: Stage
    /// Actual minus expected, in percentage points. Positive = burning faster
    /// than the window (deficit); negative = slower (reserve).
    let deltaPercent: Double
    let expectedUsedPercent: Double
    let actualUsedPercent: Double
    /// Seconds from `now` until 100% at the current burn rate. Nil when the
    /// current rate lasts past the reset (see `willLastToReset`) or when no
    /// burn has happened yet.
    let etaSeconds: TimeInterval?
    let willLastToReset: Bool
    /// Remaining capacity divided by projected remaining burn. >1 means
    /// headroom (can burn faster and still last); <1 means over pace.
    let speedMultiplierToReset: Double?

    /// Core estimator. Mirrors CodexBar `UsagePace.weekly`:
    /// - requires a future `resetsAt` inside the window
    /// - linear expectation, with optional workday-weighted progress for
    ///   weekly windows (Mon–Fri style `workDays` in 2..<7)
    /// - stage thresholds |d|<=2 on track, <=6 slightly, <=12 ahead/behind,
    ///   else far
    /// - linear burn projection for ETA / lasts-until-reset
    static func estimate(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        now: Date = Date(),
        defaultWindowMinutes: Int = 10_080,
        workDays: Int? = nil,
        calendar: Calendar = .current
    ) -> UsagePace? {
        guard let resetsAt else { return nil }
        let minutes = windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let elapsed = clamp(duration - timeUntilReset, 0...duration)

        let workdayProgress: WorkdayProgress? = {
            if let workDays, workDays >= 2, workDays < 7, minutes == 10_080 {
                return Self.workdayProgress(now: now, duration: duration,
                                            resetsAt: resetsAt, workDays: workDays,
                                            calendar: calendar)
            }
            return nil
        }()

        let expected = workdayProgress.map(\.expectedUsedPercent)
            ?? clamp(elapsed / duration * 100, 0...100)
        let actual = clamp(usedPercent, 0...100)
        if elapsed == 0, actual > 0 { return nil }

        let delta = actual - expected
        let stage = Self.stage(for: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        let paceElapsed = workdayProgress?.elapsedSeconds ?? elapsed
        let effectiveRemaining = workdayProgress?.remainingSeconds ?? timeUntilReset
        let projectedRemaining = paceElapsed > 0
            ? actual * effectiveRemaining / paceElapsed : 0
        let multiplier = Self.safeMultiplier(remaining: 100 - actual,
                                             projected: projectedRemaining)
        if actual >= 100 {
            etaSeconds = 0
        } else if paceElapsed > 0, actual > 0 {
            let rate = actual / paceElapsed
            if rate > 0 {
                let candidate = (100 - actual) / rate
                if candidate >= effectiveRemaining {
                    willLastToReset = true
                } else if workdayProgress != nil, let workDays {
                    etaSeconds = Self.wallClockInterval(from: now, to: resetsAt,
                                                        workSeconds: candidate,
                                                        workDays: workDays,
                                                        calendar: calendar)
                        ?? candidate
                } else {
                    etaSeconds = candidate
                }
            }
        } else if paceElapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(stage: stage, deltaPercent: delta,
                         expectedUsedPercent: expected, actualUsedPercent: actual,
                         etaSeconds: etaSeconds, willLastToReset: willLastToReset,
                         speedMultiplierToReset: multiplier)
    }

    /// Convenience over `LimitWindow`. Applies CodexBar's display gates:
    /// needs a fraction + reset + known length, nonzero remaining, and at
    /// least 3% of the window elapsed (earlier the projection is noise).
    static func estimate(for window: LimitWindow, now: Date = Date()) -> UsagePace? {
        guard let fraction = window.usedFraction,
              window.resetsAt != nil,
              window.windowMinutes != nil || window.inferredWindowMinutes != nil
        else { return nil }
        guard fraction < 1.0 else { return nil }
        guard let pace = estimate(usedPercent: fraction * 100,
                                  windowMinutes: window.effectiveWindowMinutes,
                                  resetsAt: window.resetsAt, now: now)
        else { return nil }
        guard pace.expectedUsedPercent >= 3 else { return nil }
        return pace
    }

    // MARK: - Internals (CodexBar parity)

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }

    private static func safeMultiplier(remaining: Double, projected: Double) -> Double? {
        guard remaining > 0, projected > 0 else { return nil }
        let multiplier = remaining / projected
        return multiplier.isFinite ? multiplier : nil
    }

    private struct WorkdayProgress {
        let workDays: Int
        let totalSeconds: TimeInterval
        let elapsedSeconds: TimeInterval
        let remainingSeconds: TimeInterval
        var expectedUsedPercent: Double {
            clamp(elapsedSeconds / totalSeconds * 100, 0...100)
        }
    }

    private static func workdayProgress(now: Date, duration: TimeInterval,
                                        resetsAt: Date, workDays: Int,
                                        calendar: Calendar) -> WorkdayProgress? {
        let windowStart = resetsAt.addingTimeInterval(-duration)
        var total: TimeInterval = 0, elapsed: TimeInterval = 0, remaining: TimeInterval = 0
        var cursor = windowStart
        while cursor < resetsAt {
            guard let nextDay = calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: cursor)),
                  nextDay > cursor
            else { return nil }
            let sliceEnd = min(nextDay, resetsAt)
            if isWorkday(cursor, calendar: calendar, workDays: workDays) {
                total += sliceEnd.timeIntervalSince(cursor)
                if now > cursor { elapsed += min(now, sliceEnd).timeIntervalSince(cursor) }
                if now < sliceEnd { remaining += sliceEnd.timeIntervalSince(max(now, cursor)) }
            }
            cursor = sliceEnd
        }
        guard total > 0 else { return nil }
        return WorkdayProgress(workDays: workDays, totalSeconds: total,
                               elapsedSeconds: elapsed, remainingSeconds: remaining)
    }

    private static func wallClockInterval(from now: Date, to resetsAt: Date,
                                          workSeconds: TimeInterval, workDays: Int,
                                          calendar: Calendar) -> TimeInterval? {
        guard workSeconds > 0 else { return 0 }
        var remaining = workSeconds
        var cursor = now
        while cursor < resetsAt {
            guard let nextDay = calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: cursor)),
                  nextDay > cursor
            else { return nil }
            let sliceEnd = min(nextDay, resetsAt)
            if isWorkday(cursor, calendar: calendar, workDays: workDays) {
                let available = sliceEnd.timeIntervalSince(cursor)
                if remaining <= available {
                    return cursor.addingTimeInterval(remaining).timeIntervalSince(now)
                }
                remaining -= available
            }
            cursor = sliceEnd
        }
        return nil
    }

    private static func isWorkday(_ date: Date, calendar: Calendar, workDays: Int) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let iso = weekday == 1 ? 7 : weekday - 1
        return iso <= workDays
    }
}

private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}
