import Foundation

/// Une unité intérieure telle que déclarée dans le compte Comfort Cloud.
struct DeviceInfo: Identifiable, Hashable {
    let guid: String
    let name: String
    let group: String
    let model: String

    /// Capacités déclarées par l'unité : toutes ne savent pas chauffer, et
    /// certaines n'ont ni oscillation horizontale ni nanoe. Se fier à ces
    /// drapeaux évite de proposer des commandes qui échoueront.
    let supportsHeat: Bool
    let supportsCool: Bool
    let supportsDry: Bool
    let supportsFan: Bool
    let supportsAuto: Bool
    let supportsNanoe: Bool
    let supportsHorizontalSwing: Bool

    var id: String { guid }

    init?(json: [String: Any]) {
        guard let guid = json["deviceGuid"] as? String else { return nil }
        // Un appareil sans bloc `parameters` est d'un autre type (Aquarea,
        // passerelle…) : il ne se pilote pas avec cette API.
        guard json["parameters"] != nil else { return nil }

        self.guid = guid
        self.name = json["deviceName"] as? String ?? "Climatiseur"
        self.group = json["groupName"] as? String ?? "Ma maison"
        self.model = json["deviceModuleNumber"] as? String ?? ""

        func flag(_ key: String) -> Bool {
            if let value = json[key] as? Int { return value == 1 }
            if let value = json[key] as? Bool { return value }
            return false
        }

        self.supportsHeat = flag("heatMode")
        self.supportsCool = flag("coolMode")
        self.supportsDry = flag("dryMode")
        self.supportsFan = flag("fanMode")
        self.supportsAuto = flag("autoMode")
        self.supportsNanoe = flag("nanoe")
        self.supportsHorizontalSwing = flag("airSwingLR")
    }

    /// Modes réellement proposables à l'utilisateur pour cette unité.
    var availableModes: [OperationMode] {
        var modes: [OperationMode] = []
        if supportsAuto { modes.append(.auto) }
        if supportsHeat { modes.append(.heat) }
        if supportsCool { modes.append(.cool) }
        if supportsDry { modes.append(.dry) }
        if supportsFan { modes.append(.fan) }
        return modes.isEmpty ? [.auto, .heat, .cool, .dry, .fan] : modes
    }
}

/// État instantané d'une unité.
struct DeviceState: Equatable {
    var power: Power = .off
    var mode: OperationMode = .auto
    var fanSpeed: FanSpeed = .auto
    var targetTemperature: Double?
    var insideTemperature: Double?
    var outsideTemperature: Double?
    var horizontalSwing: AirSwingLR = .mid
    var verticalSwing: AirSwingUD = .mid
    var ecoMode: EcoMode = .auto
    var nanoe: NanoeMode = .unavailable

    init() {}

    init(json: [String: Any]) {
        // Le corps utile est encapsulé dans `parameters` sur /deviceStatus.
        let p = (json["parameters"] as? [String: Any]) ?? json

        if let raw = p["operate"] as? Int, let value = Power(rawValue: raw) { power = value }
        if let raw = p["operationMode"] as? Int, let value = OperationMode(rawValue: raw) { mode = value }
        if let raw = p["fanSpeed"] as? Int, let value = FanSpeed(rawValue: raw) { fanSpeed = value }
        if let raw = p["ecoMode"] as? Int, let value = EcoMode(rawValue: raw) { ecoMode = value }
        if let raw = p["nanoe"] as? Int, let value = NanoeMode(rawValue: raw) { nanoe = value }

        targetTemperature = Self.temperature(p["temperatureSet"])
        insideTemperature = Self.temperature(p["insideTemperature"])
        outsideTemperature = Self.temperature(p["outTemperature"])

        if let raw = p["airSwingLR"] as? Int, let value = AirSwingLR(rawValue: raw) { horizontalSwing = value }
        if let raw = p["airSwingUD"] as? Int, let value = AirSwingUD(rawValue: raw) { verticalSwing = value }

        // Le mode « auto » d'oscillation n'apparaît pas dans airSwingLR/UD :
        // il est porté par ce champ, qui prime sur les valeurs ci-dessus.
        if let raw = p["fanAutoMode"] as? Int, let auto = AirSwingAutoMode(rawValue: raw) {
            switch auto {
            case .both:
                horizontalSwing = .auto
                verticalSwing = .auto
            case .airSwingLR:
                horizontalSwing = .auto
            case .airSwingUD:
                verticalSwing = .auto
            case .disabled:
                break
            }
        }
    }

    /// Écarte la valeur sentinelle 126, qui signale une sonde absente ou
    /// injoignable et non une pièce à 126 °C.
    private static func temperature(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let value as Double: number = value
        case let value as Int: number = Double(value)
        default: number = nil
        }
        guard let number, number != ComfortCloud.invalidTemperature else { return nil }
        return number
    }
}

/// Une unité et son état, tels qu'affichés.
struct ClimateDevice: Identifiable, Equatable {
    let info: DeviceInfo
    var state: DeviceState
    /// Vrai quand l'état affiché vient du cache serveur : l'unité ne répondait
    /// pas en direct, la valeur peut dater.
    var isStale: Bool = false

    var id: String { info.guid }

    static func == (lhs: ClimateDevice, rhs: ClimateDevice) -> Bool {
        lhs.info.guid == rhs.info.guid && lhs.state == rhs.state && lhs.isStale == rhs.isStale
    }
}

// MARK: - Libellés

extension OperationMode {
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .dry: return "Déshumidification"
        case .cool: return "Froid"
        case .heat: return "Chaud"
        case .fan: return "Ventilation"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "a.circle"
        case .dry: return "humidity"
        case .cool: return "snowflake"
        case .heat: return "flame"
        case .fan: return "fan"
        }
    }
}

extension FanSpeed {
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Minimale"
        case .lowMid: return "Faible"
        case .mid: return "Moyenne"
        case .highMid: return "Forte"
        case .high: return "Maximale"
        }
    }
}

extension AirSwingUD {
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .up: return "Haut"
        case .upMid: return "Haut/milieu"
        case .mid: return "Milieu"
        case .downMid: return "Bas/milieu"
        case .down: return "Bas"
        case .swing: return "Balayage"
        }
    }
}

extension AirSwingLR {
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .left: return "Gauche"
        case .leftMid: return "Gauche/centre"
        case .mid: return "Centre"
        case .rightMid: return "Droite/centre"
        case .right: return "Droite"
        case .unavailable: return "Indisponible"
        }
    }
}
