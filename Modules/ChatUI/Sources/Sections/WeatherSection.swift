import SwiftUI

// MARK: - WeatherSection

@MainActor
struct WeatherSection: View {
    @Binding var weatherAwarenessEnabled: Bool
    @Binding var weatherLatitude: String
    @Binding var weatherLongitude: String
    @Binding var weatherRefreshMinutes: Int

    let currentWeatherSummary: String?
    let onSetWeatherAwarenessEnabled: @MainActor (Bool) -> Void
    let onSaveWeatherLocation: @MainActor (Double?, Double?) -> Void
    let onSetWeatherRefreshInterval: @MainActor (Double) -> Void

    var body: some View {
        Section("天气感知") {
            Toggle("启用天气感知", isOn: $weatherAwarenessEnabled)
                .onChange(of: weatherAwarenessEnabled) { _, newValue in
                    onSetWeatherAwarenessEnabled(newValue)
                }

            Text("根据当前天气和时段调整宠物心情与待机动作。天气变化时显示气泡。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let currentWeatherSummary, !currentWeatherSummary.isEmpty {
                HStack {
                    Text("当前天气：")
                        .font(.subheadline)
                    Text(currentWeatherSummary)
                        .font(.subheadline.weight(.medium))
                }
            } else {
                Text(weatherAwarenessEnabled ? "正在等待天气数据…" : "天气感知已关闭")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if weatherAwarenessEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("位置坐标（留空则自动通过 IP 定位）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("纬度")
                            .font(.caption)
                            .frame(width: 30)
                        TextField("如 39.9", text: $weatherLatitude)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("经度")
                            .font(.caption)
                            .frame(width: 30)
                        TextField("如 116.4", text: $weatherLongitude)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Button("保存") {
                            let lat = Double(weatherLatitude)
                            let lon = Double(weatherLongitude)
                            onSaveWeatherLocation(lat, lon)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack {
                    Text("刷新间隔")
                        .font(.caption)
                    Picker("", selection: $weatherRefreshMinutes) {
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                        Text("2 小时").tag(120)
                        Text("4 小时").tag(240)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .onChange(of: weatherRefreshMinutes) { _, newValue in
                        onSaveWeatherLocation(Double(weatherLatitude), Double(weatherLongitude))
                        onSetWeatherRefreshInterval(Double(newValue) * 60)
                    }
                }
            }
        }
    }
}
