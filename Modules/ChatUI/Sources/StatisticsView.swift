import Charts
import SwiftUI

@MainActor
public struct StatisticsView: View {
    @State private var statisticsViewModel: StatisticsViewModel

    private struct DailyInteractionChartItem: Identifiable {
        let id = UUID()
        let date: String
        let category: String
        let count: Int
    }

    private static let behaviorDisplayNames: [String: String] = [
        "idle": "发呆",
        "walk": "散步",
        "run": "跑步",
        "sleep": "睡觉",
        "eat": "吃东西",
        "drink": "喝水",
        "sit": "坐着",
        "play": "玩耍",
        "dance": "跳舞",
        "groom": "梳理",
        "chat": "聊天",
        "read": "阅读",
        "write": "写作",
        "type": "打字",
        "think": "思考",
        "react": "反应",
        "celebrate": "庆祝",
        "yawn": "打哈欠",
        "stretch": "伸懒腰",
        "bounce": "蹦跳",
        "roll": "打滚",
        "spin": "旋转",
        "love": "撒娇",
        "shy": "害羞",
        "angry": "生气",
        "sad": "伤心",
        "confused": "困惑",
        "scared": "害怕",
        "climb": "攀爬",
        "wave": "招手",
        "nod": "点头",
        "sneeze": "打喷嚏",
        "scratch": "挠痒",
        "lookAround": "张望",
        "alert": "警觉",
        "follow": "跟随",
        "listen": "倾听",
        "cheer": "欢呼",
        "phone": "打电话",
        "gift": "送礼物",
        "peek": "偷看",
        "drag": "被拖拽",
    ]

    public init(
        statisticsViewModel: StatisticsViewModel = StatisticsViewModel()
    ) {
        _statisticsViewModel = State(initialValue: statisticsViewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !statisticsViewModel.isPersistenceAvailable {
                PersistenceUnavailableBanner()
            }

            Picker("时间范围", selection: $statisticsViewModel.selectedDays) {
                Text("最近 7 天").tag(7)
                Text("最近 30 天").tag(30)
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statisticsSection("心情曲线", subtitle: "纵轴 0-100 表示心情值，横轴为时间") {
                        if statisticsViewModel.moodHistory.isEmpty {
                            emptyPlaceholder("暂无心情数据，点击宠物可产生心情变化")
                        } else {
                            Chart {
                                ForEach(statisticsViewModel.moodHistory) { point in
                                    LineMark(
                                        x: .value("时间", point.timestamp),
                                        y: .value("心情值", point.happiness)
                                    )
                                    .foregroundStyle(by: .value("宠物", point.petName))
                                    .interpolationMethod(.catmullRom)

                                    PointMark(
                                        x: .value("时间", point.timestamp),
                                        y: .value("心情值", point.happiness)
                                    )
                                    .foregroundStyle(by: .value("宠物", point.petName))
                                    .symbolSize(20)
                                }
                            }
                            .chartYScale(domain: 0 ... 100)
                            .chartYAxisLabel("心情值")
                            .chartXAxis {
                                AxisMarks(values: .automatic) { _ in
                                    AxisGridLine()
                                    AxisValueLabel(format: .dateTime.month().day().hour().minute())
                                }
                            }
                            .frame(height: 220)
                        }
                    }

                    statisticsSection("宠物行为分布", subtitle: "按行为统计宠物状态切换次数") {
                        if statisticsViewModel.behaviorCounts.isEmpty {
                            emptyPlaceholder("暂无宠物行为数据")
                        } else {
                            Chart {
                                ForEach(statisticsViewModel.behaviorCounts) { item in
                                    BarMark(
                                        x: .value("行为", Self.localizedBehavior(item.state)),
                                        y: .value("次数", item.count)
                                    )
                                    .foregroundStyle(by: .value("宠物", item.petName))
                                    .annotation(position: .top, alignment: .center) {
                                        Text("\(item.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .chartYAxisLabel("次数")
                            .chartXAxis {
                                AxisMarks { _ in
                                    AxisValueLabel()
                                        .font(.caption)
                                }
                            }
                            .frame(height: 220)
                        }
                    }

                    statisticsSection("每日互动统计", subtitle: "按点击、互动、游戏统计每日活动") {
                        if statisticsViewModel.dailyInteractions.isEmpty {
                            emptyPlaceholder("暂无每日互动数据")
                        } else {
                            Chart {
                                ForEach(dailyInteractionChartItems) { item in
                                    BarMark(
                                        x: .value("日期", Self.shortDate(item.date)),
                                        y: .value("次数", item.count)
                                    )
                                    .foregroundStyle(by: .value("类型", item.category))
                                }
                            }
                            .chartForegroundStyleScale([
                                "点击": Color.blue,
                                "互动": Color.green,
                                "游戏": Color.purple,
                            ])
                            .chartYAxisLabel("次数")
                            .frame(height: 220)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }

            if statisticsViewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 520)
        .task {
            await statisticsViewModel.refresh()
        }
        .onChange(of: statisticsViewModel.selectedDays) { _, _ in
            Task {
                await statisticsViewModel.refresh()
            }
        }
    }

    @ViewBuilder
    private func statisticsSection<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    @ViewBuilder
    private func emptyPlaceholder(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 40)
            Spacer()
        }
    }

    /// "2026-03-29" → "03/29"
    private static func shortDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3 else { return dateString }
        return "\(parts[1])/\(parts[2])"
    }

    private static func localizedBehavior(_ state: String) -> String {
        behaviorDisplayNames[state] ?? state
    }

    private var dailyInteractionChartItems: [DailyInteractionChartItem] {
        statisticsViewModel.dailyInteractions.flatMap { item in
            [
                DailyInteractionChartItem(date: item.date, category: "点击", count: item.clicks),
                DailyInteractionChartItem(date: item.date, category: "互动", count: item.interactions),
                DailyInteractionChartItem(date: item.date, category: "游戏", count: item.games),
            ]
            .filter { $0.count > 0 }
        }
    }
}

private struct PersistenceUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text("数据不可用 — 持久化未启用")
                .font(.subheadline)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
