import AppKit
import QuartzCore
import SwiftUI

/// 回放日期：較大的日期按鈕與月曆，選年／月不會觸發錄影查詢，選日期才套用。
struct PlaybackDatePicker: View {
    @Binding var selection: Date
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                Text(selection, format: .dateTime.year().month(.twoDigits).day(.twoDigits).weekday(.abbreviated))
                    .monospacedDigit()
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
        }
        .buttonStyle(.borderless)
        .help("選擇回放日期")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PlaybackCalendarPopover(selection: selection) { date in
                selection = PlaybackCalendarMonth.calendar.startOfDay(for: date)
                isPresented = false
            }
        }
    }
}

struct PlaybackCalendarMonth {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    let start: Date
    let days: [Date?]

    init(containing date: Date) {
        let calendar = Self.calendar
        let parts = calendar.dateComponents([.year, .month], from: date)
        let monthStart = calendar.date(from: parts)!
        start = monthStart
        let leading = calendar.component(.weekday, from: monthStart) - 1
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        // 固定六週，換月時不會跳動或改變彈出視窗高度。
        days = (0..<42).map { index in
            let offset = index - leading
            guard (0..<count).contains(offset) else { return nil }
            return calendar.date(byAdding: .day, value: offset, to: monthStart)
        }
    }
}

struct PlaybackCalendarPopover: View {
    let selection: Date
    let onSelect: (Date) -> Void
    @State private var displayedMonth: Date
    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 4), count: 7)
    private var calendar: Calendar { PlaybackCalendarMonth.calendar }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var year: Int { calendar.component(.year, from: displayedMonth) }
    private var month: Int { calendar.component(.month, from: displayedMonth) }
    private var currentYear: Int { calendar.component(.year, from: today) }
    private var atLatestMonth: Bool { displayedMonth >= PlaybackCalendarMonth(containing: today).start }

    init(selection: Date, onSelect: @escaping (Date) -> Void) {
        self.selection = selection; self.onSelect = onSelect
        _displayedMonth = State(initialValue: PlaybackCalendarMonth(containing: selection).start)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .help("上一個月").accessibilityLabel("上一個月")
                Picker("年份", selection: Binding(get: { year }, set: { setMonth(year: $0, month: month) })) {
                    ForEach(Array((min(1970, year)...max(currentYear, year)).reversed()), id: \.self) { value in
                        Text("\(String(value)) 年").tag(value)
                    }
                }
                .labelsHidden().frame(width: 105)
                Picker("月份", selection: Binding(get: { month }, set: { setMonth(year: year, month: $0) })) {
                    ForEach(1...12, id: \.self) { value in
                        Text("\(value) 月").tag(value)
                            .disabled(year == currentYear && value > calendar.component(.month, from: today))
                    }
                }
                .labelsHidden().frame(width: 85)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .help("下一個月").accessibilityLabel("下一個月").disabled(atLatestMonth)
            }
            .buttonStyle(.borderless)

            CalendarMonthScroll(month: displayedMonth, onMonth: { shiftMonth($0) }) {
              LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(["日", "一", "二", "三", "四", "五", "六"].enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(height: 22)
                }
                ForEach(Array(PlaybackCalendarMonth(containing: displayedMonth).days.enumerated()), id: \.offset) { _, date in
                    if let date { dayButton(date) } else { Color.clear.frame(width: 40, height: 38).accessibilityHidden(true) }
                }
            }
              }
            .frame(height: 280)
            .help("上下滾動切換月份；點選日期開始回放")
            Divider()
            HStack {
                Text("選取：\(selection.formatted(.dateTime.month().day().weekday()))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("今天") { onSelect(today) }.buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 336)
    }

    private func dayButton(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let future = date > today
        return Button { onSelect(date) } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 15, weight: selected || isToday ? .semibold : .regular).monospacedDigit())
                .frame(width: 40, height: 38)
                .foregroundStyle(selected ? Color.white : (future ? Color.secondary.opacity(0.4) : Color.primary))
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if isToday && !selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(future)
        .help(date.formatted(.dateTime.year().month().day().weekday()))
        .accessibilityLabel(date.formatted(.dateTime.year().month().day().weekday()))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setMonth(year: Int, month: Int) {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return }
        displayedMonth = min(date, PlaybackCalendarMonth(containing: today).start)
    }

    private func shiftMonth(_ offset: Int) {
        guard let date = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = min(date, PlaybackCalendarMonth(containing: today).start)
    }
}

/// 用真正的原生捲動容器接收滾輪；日期按鈕仍由內部 SwiftUI 處理點擊。
/// 不使用透明背景事件監聽，避免彈出視窗中事件的視窗／座標判斷擋掉滾動。
struct CalendarMonthScroll<Content: View>: NSViewRepresentable {
    let month: Date
    let onMonth: (Int) -> Void
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(month: Date, onMonth: @escaping (Int) -> Void, @ViewBuilder content: () -> Content) {
        self.month = month; self.onMonth = onMonth; self.content = content()
    }

    func makeNSView(context: Context) -> WheelView {
        let view = WheelView()
        view.drawsBackground = false
        view.hasVerticalScroller = false
        view.hasHorizontalScroller = false
        view.documentView = view.months
        return view
    }

    func updateNSView(_ view: WheelView, context: Context) {
        view.onMonth = onMonth
        view.setContent(content, month: month, animated: !reduceMotion)
    }

    final class WheelView: NSScrollView {
        var onMonth: (Int) -> Void = { _ in }
        let months: NSView = {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 304, height: 280))
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            return view
        }()
        private var host: NSHostingView<Content>?
        private var displayedMonth: Date?
        private var animationID = UUID()
        private var animating = false
        private var accumulated: CGFloat = 0
        private var lastStep: TimeInterval = -.infinity

        override func layout() {
            super.layout()
            months.frame = NSRect(origin: .zero, size: contentSize)
            if !animating { host?.frame = months.bounds }
        }

        func setContent(_ content: Content, month: Date, animated: Bool) {
            guard displayedMonth != month else { host?.rootView = content; return }
            let previousMonth = displayedMonth
            displayedMonth = month
            let old = host
            let next = NSHostingView(rootView: content)
            next.wantsLayer = true
            let bounds = months.bounds
            next.frame = bounds
            months.addSubview(next)
            host = next
            animationID = UUID()
            let id = animationID
            guard animated, let old, let previousMonth, bounds.height > 0 else {
                old?.removeFromSuperview()
                animating = false
                return
            }
            // 原生座標向上為正：下個月由下方滑入，前個月由上方滑入。
            let direction: CGFloat = month > previousMonth ? 1 : -1
            next.setFrameOrigin(NSPoint(x: 0, y: -direction * bounds.height))
            next.layoutSubtreeIfNeeded()
            animating = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                old.animator().setFrameOrigin(NSPoint(x: 0, y: direction * bounds.height))
                next.animator().setFrameOrigin(.zero)
            } completionHandler: { [weak self, weak old, weak next] in
                old?.removeFromSuperview()
                guard let self, self.animationID == id else { return }
                self.animating = false
                next?.frame = self.months.bounds
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.momentumPhase.isEmpty else { return }
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
            if event.phase.contains(.began) { accumulated = 0 }
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            if accumulated * delta < 0 { accumulated = 0 }
            accumulated += delta
            // Magic Mouse 也屬於精準滾動，短滑動可能只有數個像素，不能要求累積 45 像素。
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 3 : 1
            guard abs(accumulated) >= threshold, event.timestamp - lastStep >= 0.3 else { return }
            let step = accumulated > 0 ? -1 : 1
            accumulated = 0
            lastStep = event.timestamp
            onMonth(step)
        }
    }
}
