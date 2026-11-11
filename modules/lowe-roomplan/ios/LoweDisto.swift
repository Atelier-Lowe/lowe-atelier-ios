//  LoweDisto.swift – Löwe Atelier
//  Liaison Bluetooth Smart avec un télémètre Leica DISTO (D1, D2, D110…).
//  Protocole repris du projet libre FablabPPR/leica-disto-transfer :
//  service 3AB10100-…, distance 3AB10101-… (nombre 4 octets, little endian, en mètres),
//  unité 3AB10102-…, commandes 3AB10109-… ("g" = mesurer, "o" = laser allumé, "p" = laser éteint).

import Foundation
import CoreBluetooth
import ExpoModulesCore

private let kService  = CBUUID(string: "3AB10100-F831-4395-B29D-570977D5BF94")
private let kDistance = CBUUID(string: "3AB10101-F831-4395-B29D-570977D5BF94")
private let kUnit     = CBUUID(string: "3AB10102-F831-4395-B29D-570977D5BF94")
private let kCommand  = CBUUID(string: "3AB10109-F831-4395-B29D-570977D5BF94")
private let kSavedKey = "lowe.disto.peripheral"

final class LoweDistoLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  var emit: ((String, [String: Any]) -> Void)?
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var commandChar: CBCharacteristic?
  private var wantConnect = false
  private var scanTimer: Timer?
  private var lastUnit: Int = -1
  private var lastValue: Float = .nan
  private var lastTime: Date = .distantPast

  private func status(_ s: String, _ extra: [String: Any] = [:]) {
    var d = extra; d["status"] = s
    if let n = peripheral?.name { d["name"] = n }
    emit?("onDistoStatus", d)
  }

  func connect() {
    wantConnect = true
    if central == nil {
      central = CBCentralManager(delegate: self, queue: .main)   // l'état arrive dans centralManagerDidUpdateState
    } else {
      start()
    }
  }

  func disconnect() {
    wantConnect = false
    stopScan()
    if let p = peripheral { central?.cancelPeripheralConnection(p) }
    status("disconnected")
  }

  func forget() {
    UserDefaults.standard.removeObject(forKey: kSavedKey)
    disconnect()
    peripheral = nil
  }

  func send(_ cmd: String) -> Bool {
    guard let p = peripheral, p.state == .connected, let c = commandChar, let data = cmd.data(using: .ascii) else { return false }
    p.writeValue(data, for: c, type: c.properties.contains(.write) ? .withResponse : .withoutResponse)
    return true
  }

  private func start() {
    guard let c = central, wantConnect else { return }
    switch c.state {
    case .poweredOn: break
    case .unauthorized: status("error", ["message": "Bluetooth refusé : Réglages > Löwe Atelier > Bluetooth."]); return
    case .poweredOff: status("error", ["message": "Le Bluetooth de l'iPhone est coupé."]); return
    case .unsupported: status("error", ["message": "Cet appareil ne gère pas le Bluetooth Smart."]); return
    default: return
    }
    if let p = peripheral, p.state == .connected { status("connected"); return }
    // 1) appareil déjà connu
    if let s = UserDefaults.standard.string(forKey: kSavedKey), let id = UUID(uuidString: s),
       let p = c.retrievePeripherals(withIdentifiers: [id]).first {
      attach(p); return
    }
    // 2) déjà relié à l'iPhone par une autre appli
    if let p = c.retrieveConnectedPeripherals(withServices: [kService]).first {
      attach(p); return
    }
    // 3) recherche
    status("scanning")
    c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    scanTimer?.invalidate()
    scanTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      if self.peripheral?.state != .connected {
        self.stopScan()
        self.status("error", ["message": "Aucun DISTO trouvé. Allume-le et active son Bluetooth (logo Bluetooth à l'écran)."])
      }
    }
  }

  private func stopScan() {
    scanTimer?.invalidate(); scanTimer = nil
    if central?.isScanning == true { central?.stopScan() }
  }

  private func attach(_ p: CBPeripheral) {
    stopScan()
    peripheral = p
    p.delegate = self
    status("connecting")
    central?.connect(p, options: nil)
  }

  // MARK: CBCentralManagerDelegate
  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state == .poweredOn { start() }
    else if wantConnect && c.state != .unknown && c.state != .resetting { start() }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
    let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
    let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let low = name.lowercased()
    if services.contains(kService) || low.contains("disto") || low.contains("stabila") {
      attach(p)
    }
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    UserDefaults.standard.set(p.identifier.uuidString, forKey: kSavedKey)
    p.discoverServices([kService])
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    status("error", ["message": "Connexion impossible au DISTO. Réessaie."])
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    commandChar = nil
    status("disconnected")
    // le DISTO s'éteint tout seul : on se reconnecte dès qu'il revient
    if wantConnect { c.connect(p, options: nil) }
  }

  // MARK: CBPeripheralDelegate
  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let s = p.services?.first(where: { $0.uuid == kService }) else {
      status("error", ["message": "Ce DISTO ne propose pas le service de mesure attendu."])
      return
    }
    p.discoverCharacteristics(nil, for: s)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    var chars: [String] = []
    for c in s.characteristics ?? [] {
      chars.append(c.uuid.uuidString)
      if c.uuid == kCommand { commandChar = c }
      // on s'abonne à tout ce qui peut prévenir (certains DISTO l'exigent)
      if c.properties.contains(.notify) || c.properties.contains(.indicate) {
        p.setNotifyValue(true, for: c)
      }
    }
    status("connected", ["chars": chars])
  }

  func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
    if let e = error as NSError?, c.uuid == kDistance {
      status("error", ["message": "Le DISTO refuse l'abonnement (\(e.code)). Désactive puis réactive son Bluetooth."])
    }
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard error == nil, let data = c.value else { return }
    if c.uuid == kUnit, let b = data.first { lastUnit = Int(b); return }
    guard c.uuid == kDistance, data.count >= 4 else { return }
    let b = [UInt8](data)
    let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    let v = Float(bitPattern: bits)
    guard v.isFinite, v > 0, v < 1000 else { return }
    // certains DISTO renvoient la même valeur deux fois : on ignore le doublon immédiat
    let now = Date()
    if v == lastValue && now.timeIntervalSince(lastTime) < 0.6 { return }
    lastValue = v; lastTime = now
    emit?("onDistoMeasure", ["meters": Double(v), "unit": lastUnit, "raw": data.map { String(format: "%02x", $0) }.joined()])
  }
}

public class LoweDistoModule: Module {
  private let link = LoweDistoLink()

  public func definition() -> ModuleDefinition {
    Name("LoweDisto")
    Events("onDistoStatus", "onDistoMeasure")

    OnCreate {
      self.link.emit = { [weak self] name, body in self?.sendEvent(name, body) }
    }

    Function("connect") { DispatchQueue.main.async { self.link.connect() } }
    Function("disconnect") { DispatchQueue.main.async { self.link.disconnect() } }
    Function("forget") { DispatchQueue.main.async { self.link.forget() } }
    Function("command") { (cmd: String) in
      DispatchQueue.main.async { _ = self.link.send(cmd) }
    }
  }
}
