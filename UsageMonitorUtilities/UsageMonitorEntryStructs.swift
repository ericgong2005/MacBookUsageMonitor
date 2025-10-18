import Foundation

public struct BatteryChargeEntry: Equatable, CustomStringConvertible {
    public var EntryTime: UInt32
    public var Amperage: Int16
    public var RawCurrentCapacity: Int16
    public var Voltage: Int16
    public var CellVoltage0: Int16
    public var CellVoltage1: Int16
    public var CellVoltage2: Int16
    public var CurrentCapacity: Int8
    public var PresentDOD0: Int8
    public var PresentDOD1: Int8
    public var PresentDOD2: Int8

    public init(
        EntryTime: UInt32, Amperage: Int16, RawCurrentCapacity: Int16,
        Voltage: Int16, CellVoltage0: Int16, CellVoltage1: Int16, CellVoltage2: Int16,
        CurrentCapacity: Int8, PresentDOD0: Int8, PresentDOD1: Int8, PresentDOD2: Int8)
    {
        self.EntryTime = EntryTime
        self.Amperage = Amperage
        self.RawCurrentCapacity = RawCurrentCapacity
        self.Voltage = Voltage
        self.CellVoltage0 = CellVoltage0
        self.CellVoltage1 = CellVoltage1
        self.CellVoltage2 = CellVoltage2
        self.CurrentCapacity = CurrentCapacity
        self.PresentDOD0 = PresentDOD0
        self.PresentDOD1 = PresentDOD1
        self.PresentDOD2 = PresentDOD2
    }

    public static let byteSize =
        MemoryLayout<UInt32>.size +
        MemoryLayout<Int16>.size * 6 +
        MemoryLayout<Int8>.size  * 4

    public func encode(into data: inout Data) {
        data.appendInteger(EntryTime)
        data.appendInteger(Amperage)
        data.appendInteger(RawCurrentCapacity)
        data.appendInteger(Voltage)
        data.appendInteger(CellVoltage0)
        data.appendInteger(CellVoltage1)
        data.appendInteger(CellVoltage2)
        data.appendInteger(CurrentCapacity)
        data.appendInteger(PresentDOD0)
        data.appendInteger(PresentDOD1)
        data.appendInteger(PresentDOD2)
    }

    public static func decode(from data: Data, at offset: Int) -> BatteryChargeEntry? {
        guard offset + byteSize <= data.count else { return nil }
        return BatteryChargeEntry(
            EntryTime: data.readInteger(at: offset, as: UInt32.self),
            Amperage: data.readInteger(at: offset + 4, as: Int16.self),
            RawCurrentCapacity: data.readInteger(at: offset + 6, as: Int16.self),
            Voltage: data.readInteger(at: offset + 8, as: Int16.self),
            CellVoltage0: data.readInteger(at: offset + 10, as: Int16.self),
            CellVoltage1: data.readInteger(at: offset + 12, as: Int16.self),
            CellVoltage2: data.readInteger(at: offset + 14, as: Int16.self),
            CurrentCapacity: data.readInteger(at: offset + 16, as: Int8.self),
            PresentDOD0: data.readInteger(at: offset + 17, as: Int8.self),
            PresentDOD1: data.readInteger(at: offset + 18, as: Int8.self),
            PresentDOD2: data.readInteger(at: offset + 19, as: Int8.self)
        )
    }

    public var description: String {
        "BatteryChargeEntry(EntryTime: \(EntryTime), Amperage: \(Amperage), RawCurrentCapacity: \(RawCurrentCapacity), " +
        "Voltage: \(Voltage), CellVoltages: [\(CellVoltage0), \(CellVoltage1), \(CellVoltage2)], " +
        "CurrentCapacity: \(CurrentCapacity), PresentDOD: [\(PresentDOD0), \(PresentDOD1), \(PresentDOD2)])"
    }
}

public struct BatteryHealthEntry: Equatable, CustomStringConvertible {
    public var EntryTime: UInt32
    public var CycleCount: UInt16
    public var RawMaxCapacity: Int16
    public var QMax0: Int16
    public var QMax1: Int16
    public var QMax2: Int16
    public var WeightedRa0: Int8
    public var WeightedRa1: Int8
    public var WeightedRa2: Int8
    public var ExternalConnected: Int8

    public init(EntryTime: UInt32, CycleCount: UInt16, RawMaxCapacity: Int16, QMax0: Int16, QMax1: Int16, QMax2: Int16, 
                WeightedRa0: Int8, WeightedRa1: Int8, WeightedRa2: Int8, ExternalConnected: Int8)
    {
        self.EntryTime = EntryTime
        self.CycleCount = CycleCount
        self.RawMaxCapacity = RawMaxCapacity
        self.QMax0 = QMax0
        self.QMax1 = QMax1
        self.QMax2 = QMax2
        self.WeightedRa0 = WeightedRa0
        self.WeightedRa1 = WeightedRa1
        self.WeightedRa2 = WeightedRa2
        self.ExternalConnected = ExternalConnected
    }

    public static let byteSize =
        MemoryLayout<UInt32>.size +
        MemoryLayout<UInt16>.size +
        MemoryLayout<Int16>.size * 4 +
        MemoryLayout<Int8>.size  * 4

    public func encode(into data: inout Data) {
        data.appendInteger(EntryTime)
        data.appendInteger(CycleCount)
        data.appendInteger(RawMaxCapacity)
        data.appendInteger(QMax0)
        data.appendInteger(QMax1)
        data.appendInteger(QMax2)
        data.appendInteger(WeightedRa0)
        data.appendInteger(WeightedRa1)
        data.appendInteger(WeightedRa2)
        data.appendInteger(ExternalConnected)
    }

    public static func decode(from data: Data, at offset: Int) -> BatteryHealthEntry? {
        guard offset + byteSize <= data.count else { return nil }
        return BatteryHealthEntry(
            EntryTime: data.readInteger(at: offset, as: UInt32.self),
            CycleCount: data.readInteger(at: offset + 4, as: UInt16.self),
            RawMaxCapacity: data.readInteger(at: offset + 6, as: Int16.self),
            QMax0: data.readInteger(at: offset + 8, as: Int16.self),
            QMax1: data.readInteger(at: offset + 10, as: Int16.self),
            QMax2: data.readInteger(at: offset + 12, as: Int16.self),
            WeightedRa0: data.readInteger(at: offset + 14, as: Int8.self),
            WeightedRa1: data.readInteger(at: offset + 15, as: Int8.self),
            WeightedRa2: data.readInteger(at: offset + 16, as: Int8.self),
            ExternalConnected: data.readInteger(at: offset + 17, as: Int8.self)
        )
    }

    public var description: String {
        "BatteryHealthEntry(EntryTime: \(EntryTime), CycleCount: \(CycleCount), RawMaxCapacity: \(RawMaxCapacity), " +
        "QMax: [\(QMax0), \(QMax1), \(QMax2)], WeightedRa: [\(WeightedRa0), \(WeightedRa1), \(WeightedRa2)], " +
        "ExternalConnected: \(ExternalConnected))"
    }
}

public enum ScreenStateEnum: Int8, CustomStringConvertible {
    case unlocked = 0
    case locked = 1
    public var description: String { String(rawValue) }  
    public var label: String { self == .locked ? "Lock" : "Unlock" }
}

public struct ScreenStateEntry: Equatable, CustomStringConvertible {
    public var EntryTime: UInt32
    public var ScreenState: ScreenStateEnum

    public init(EntryTime: UInt32, ScreenState: ScreenStateEnum)
    {
        self.EntryTime = EntryTime
        self.ScreenState = ScreenState
    }

    public static let byteSize =
        MemoryLayout<UInt32>.size + MemoryLayout<Int8>.size

    public func encode(into data: inout Data) {
        data.appendInteger(EntryTime)
        data.appendInteger(ScreenState.rawValue)
    }

    public static func decode(from data: Data, at offset: Int) -> ScreenStateEntry? {
        guard offset + byteSize <= data.count else { return nil }
        let time: UInt32 = data.readInteger(at: offset, as: UInt32.self)
        let raw: Int8 = data.readInteger(at: offset + 4, as: Int8.self)
        guard let state = ScreenStateEnum(rawValue: raw) else { return nil }
        return ScreenStateEntry(EntryTime: time, ScreenState: state)
    }

    public var description: String {
        "ScreenStateEntry(EntryTime: \(EntryTime), ScreenState: \(ScreenState.label))"
    }
}

