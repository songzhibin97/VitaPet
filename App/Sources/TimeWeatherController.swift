import CoreLocation
import Foundation

enum TimePeriod: String, CaseIterable {
    case dawn
    case morning
    case afternoon
    case eveningEarly
    case evening
    case night

    static func current() -> TimePeriod {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<8:
            return .dawn
        case 8..<12:
            return .morning
        case 12..<14:
            return .afternoon
        case 14..<18:
            return .eveningEarly
        case 18..<22:
            return .evening
        default:
            return .night
        }
    }

    var moodDelta: Int {
        switch self {
        case .dawn:
            return 3
        case .morning:
            return 2
        case .afternoon, .eveningEarly:
            return 0
        case .evening:
            return -1
        case .night:
            return -3
        }
    }

    var behaviorMultipliers: [String: Double] {
        switch self {
        case .dawn:
            return ["sleep": 0.3, "stretch": 3.0, "yawn": 3.0, "walk": 1.5]
        case .morning:
            return ["play": 2.0, "walk": 1.5, "dance": 1.5, "run": 1.5]
        case .afternoon:
            return ["sleep": 2.0, "sit": 2.0, "yawn": 1.5]
        case .eveningEarly:
            return [:]
        case .evening:
            return ["sit": 2.0, "read": 2.0, "groom": 1.5, "sleep": 1.3]
        case .night:
            return ["sleep": 3.0, "sit": 1.5, "walk": 0.3, "run": 0.1, "play": 0.2, "dance": 0.1, "bounce": 0.2]
        }
    }

    var greeting: String? {
        switch self {
        case .dawn:
            return "早上好~☀️"
        case .morning:
            return nil
        case .afternoon:
            return "午后时光~"
        case .eveningEarly:
            return nil
        case .evening:
            return "晚上好~🌙"
        case .night:
            return "晚安~💤"
        }
    }
}

struct WeatherInfo: Sendable {
    let weatherCode: Int
    let temperature: Double

    var moodDelta: Int {
        switch weatherCode {
        case 0...1:
            return 3
        case 2...3:
            return 0
        case 51...67:
            return -2
        case 71...77:
            return 5
        case 95...99:
            return -5
        default:
            return 0
        }
    }

    var temperatureMoodDelta: Int {
        if temperature > 35 || temperature < 0 {
            return -2
        }
        return 0
    }

    var bubble: String {
        switch weatherCode {
        case 0...1:
            return temperature > 30 ? "好热...☀️" : "天气真好~☀️"
        case 2...3:
            return "多云~☁️"
        case 51...55:
            return "下小雨了~🌧️"
        case 56...67:
            return "下雨了~🌧️ 不想出去..."
        case 71...77:
            return "下雪啦！❄️ 好漂亮~"
        case 95...99:
            return "打雷了！⛈️ 好可怕！"
        default:
            return "今天天气还行~"
        }
    }

    var animation: String {
        switch weatherCode {
        case 0...1:
            return temperature > 35 ? "drink" : "play"
        case 51...67:
            return "sit"
        case 71...77:
            return "celebrate"
        case 95...99:
            return "scared"
        default:
            return "idle"
        }
    }

    var behaviorMultipliers: [String: Double] {
        switch weatherCode {
        case 0...1:
            return ["play": 1.5, "dance": 1.5]
        case 51...67:
            return ["sit": 2.0, "sleep": 1.5, "walk": 0.5, "run": 0.3]
        case 71...77:
            return ["play": 2.0, "celebrate": 2.0, "bounce": 2.0]
        case 95...99:
            return ["sleep": 2.0, "sit": 1.5, "scared": 2.0, "walk": 0.3]
        default:
            return [:]
        }
    }

    var summary: String {
        "\(bubble) \(Int(temperature.rounded()))°C"
    }
}

@MainActor
final class TimeWeatherController: NSObject, CLLocationManagerDelegate {
    private static let weatherEnabledDefaultsKey = "weather.enabled"

    private var timeCheckTimer: Timer?
    private var weatherTimer: Timer?
    private var moodDecayTimer: Timer?
    private var currentPeriod: TimePeriod
    private(set) var currentWeather: WeatherInfo?
    private(set) var weatherEnabled: Bool
    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?

    var onTimePeriodChanged: ((TimePeriod, TimePeriod) -> Void)?
    var onWeatherUpdated: ((WeatherInfo) -> Void)?
    var onMoodDecay: (() -> Void)?

    var currentBehaviorMultipliers: [String: Double] {
        var multipliers = currentPeriod.behaviorMultipliers
        if let weather = currentWeather {
            for (key, value) in weather.behaviorMultipliers {
                multipliers[key] = (multipliers[key] ?? 1.0) * value
            }
        }
        return multipliers
    }

    var currentWeatherSummary: String? {
        currentWeather?.summary
    }

    override init() {
        currentPeriod = TimePeriod.current()
        weatherEnabled = UserDefaults.standard.object(forKey: Self.weatherEnabledDefaultsKey) as? Bool ?? true
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        // 只在天气功能开启且无手动坐标时请求系统定位
        if weatherEnabled, manualLatitude == nil, manualLongitude == nil, CLLocationManager.locationServicesEnabled() {
            locationManager.startUpdatingLocation()
        }
    }

    func start() {
        checkTimePeriod()

        timeCheckTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTimePeriod()
            }
        }

        moodDecayTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onMoodDecay?()
            }
        }

        if weatherEnabled {
            startWeatherUpdates()
        }
    }

    func stop() {
        timeCheckTimer?.invalidate()
        timeCheckTimer = nil
        weatherTimer?.invalidate()
        weatherTimer = nil
        moodDecayTimer?.invalidate()
        moodDecayTimer = nil
        locationManager.stopUpdatingLocation()
    }

    func setWeatherEnabled(_ enabled: Bool) {
        weatherEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.weatherEnabledDefaultsKey)

        if enabled {
            startWeatherUpdates()
        } else {
            weatherTimer?.invalidate()
            weatherTimer = nil
            locationManager.stopUpdatingLocation()
            currentWeather = nil
        }
    }

    func refreshWeather() {
        resolveLocationAndFetch()
    }

    private func checkTimePeriod() {
        let newPeriod = TimePeriod.current()
        if newPeriod != currentPeriod {
            let oldPeriod = currentPeriod
            currentPeriod = newPeriod
            onTimePeriodChanged?(oldPeriod, newPeriod)
        }
    }

    /// 用户手动设置的坐标（设置界面可配置）
    var manualLatitude: Double? {
        get { UserDefaults.standard.object(forKey: "weather.latitude") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "weather.latitude") }
    }
    var manualLongitude: Double? {
        get { UserDefaults.standard.object(forKey: "weather.longitude") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "weather.longitude") }
    }

    /// 天气刷新间隔（秒），默认 2 小时
    var weatherRefreshInterval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "weather.refreshInterval")
            return val > 0 ? val : 7200
        }
        set { UserDefaults.standard.set(newValue, forKey: "weather.refreshInterval") }
    }

    private func startWeatherUpdates() {
        weatherTimer?.invalidate()

        // 重新启动系统定位（可能被 stop/setWeatherEnabled(false) 关掉了）
        if manualLatitude == nil, manualLongitude == nil, CLLocationManager.locationServicesEnabled() {
            locationManager.startUpdatingLocation()
        }

        weatherTimer = Timer.scheduledTimer(withTimeInterval: weatherRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchWeather()
            }
        }

        // 初始获取
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.resolveLocationAndFetch()
        }
    }

    private func resolveLocationAndFetch() {
        // 优先用手动坐标
        if let lat = manualLatitude, let lon = manualLongitude {
            fetchWeatherAt(latitude: lat, longitude: lon)
            return
        }

        // 尝试 CoreLocation
        if let location = lastLocation ?? locationManager.location {
            fetchWeatherAt(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            return
        }

        // Fallback: IP 地理定位
        fetchLocationByIP()
    }

    private func fetchLocationByIP() {
        guard let url = URL(string: "https://ipapi.co/json/") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = Self.doubleValue(json["latitude"]),
                  let lon = Self.doubleValue(json["longitude"]) else { return }
            DispatchQueue.main.async {
                self?.lastLocation = CLLocation(latitude: lat, longitude: lon)
                self?.fetchWeatherAt(latitude: lat, longitude: lon)
            }
        }.resume()
    }

    private func fetchWeather() {
        resolveLocationAndFetch()
    }

    private func fetchWeatherAt(latitude: Double, longitude: Double) {
        guard weatherEnabled else { return }

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current_weather=true"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, error == nil else { return }

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let current = json["current_weather"] as? [String: Any],
                let weatherCode = current["weathercode"] as? Int,
                let temperature = current["temperature"] as? Double
            else { return }

            let info = WeatherInfo(weatherCode: weatherCode, temperature: temperature)
            DispatchQueue.main.async {
                let oldCode = self?.currentWeather?.weatherCode
                self?.currentWeather = info
                // 只在天气状况变化时才通知（首次或 weatherCode 变了）
                if oldCode == nil || oldCode != weatherCode {
                    self?.onWeatherUpdated?(info)
                }
            }
        }.resume()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }

        Task { @MainActor in
            lastLocation = location
            locationManager.stopUpdatingLocation()
            fetchWeather()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}

private extension TimeWeatherController {
    nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }
}
