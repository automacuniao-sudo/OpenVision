// OpenVision - DeviceStatusTool.swift
// Read safe on-device status such as battery level and charging state.

import Foundation
import UIKit

/// Read basic iPhone status without private APIs or extra permissions.
struct DeviceStatusTool: NativeTool {
    let name = "device_status"
    let description = "Read the iPhone's current battery percentage, charging state, Low Power Mode, and iOS version. Use whenever the user asks about battery, charge, power, or basic phone status."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let snapshot = await MainActor.run { () -> (level: Float, state: UIDevice.BatteryState, systemVersion: String) in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            return (device.batteryLevel, device.batteryState, device.systemVersion)
        }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        let batteryText: String
        if snapshot.level >= 0 {
            batteryText = "\(Int((snapshot.level * 100).rounded()))%"
        } else {
            batteryText = "indisponível"
        }

        let stateText: String
        switch snapshot.state {
        case .unplugged:
            stateText = "fora do carregador"
        case .charging:
            stateText = "carregando"
        case .full:
            stateText = "carregado e conectado à energia"
        case .unknown:
            stateText = "estado de carga desconhecido"
        @unknown default:
            stateText = "estado de carga desconhecido"
        }

        let lowPowerText = lowPower ? "ativado" : "desativado"
        return "Bateria do iPhone: \(batteryText), \(stateText). Modo de Pouca Energia: \(lowPowerText). iOS \(snapshot.systemVersion)."
    }
}
