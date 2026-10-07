import Foundation

/// Talks to macOS's own `usbmuxd` over its Unix socket: which iPhones are on the cable, whether this Mac
/// has been trusted by them, and the few values their lockdown service answers without a session.
///
/// The setup guide opens before `~/.pogo/venv` has pymobiledevice3. usbmuxd is always running and needs
/// nothing installed, so the guide sees the phone from the very first launch; whatever needs a lockdown
/// session goes through Python once it exists.
enum Usbmux {
    struct Entry: Equatable {
        /// usbmuxd's own number for the connection; changes on every replug.
        let id: Int
        let udid: String
    }

    private static let socketPath = "/var/run/usbmuxd"
    private static let plistMessage: UInt32 = 8
    private static let version: UInt32 = 1
    private static let lockdownPort: UInt16 = 62078

    static func listDevices() -> [Entry] {
        guard let reply = request(["MessageType": "ListDevices"]),
              let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any],
                  let serial = props["SerialNumber"] as? String,
                  let id = (entry["DeviceID"] as? Int) ?? (props["DeviceID"] as? Int) else { return nil }
            // Wi-Fi entries describe a phone that isn't on the cable; the bot needs the cable.
            if let kind = props["ConnectionType"] as? String, kind != "USB" { return nil }
            return Entry(id: id, udid: serial)
        }
    }

    /// Has this Mac been trusted by the phone? macOS keeps a pair record from the moment the user taps
    /// Trust. It can outlive the trust itself (a phone that was erased); the guide asks Python when that
    /// matters.
    static func hasPairRecord(udid: String) -> Bool {
        guard let reply = request(["MessageType": "ReadPairRecord", "PairRecordID": udid]) else { return false }
        return reply["PairRecordData"] != nil
    }

    /// Name and iOS version straight from the phone's lockdown service. Both are among the values it
    /// gives without a session, so this works before the phone trusts the Mac.
    static func deviceInfo(_ device: Entry) -> (name: String, os: String)? {
        guard let values = lockdown(device, ["Request": "GetValue"])?["Value"] as? [String: Any] else { return nil }
        return ((values["DeviceName"] as? String) ?? "iPhone", (values["ProductVersion"] as? String) ?? "")
    }

    /// Developer Mode, if the phone answers without a session; nil when it wants one (then Python asks).
    static func developerMode(_ device: Entry) -> Bool? {
        let reply = lockdown(device, ["Request": "GetValue", "Domain": "com.apple.security.mac.amfi",
                                      "Key": "DeveloperModeStatus"])
        return reply?["Value"] as? Bool
    }

    // MARK: - usbmuxd requests

    private static func request(_ message: [String: Any]) -> [String: Any]? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        return exchange(fd, message)
    }

    private static func exchange(_ fd: Int32, _ message: [String: Any]) -> [String: Any]? {
        var full = message
        full["ClientVersionString"] = "IVory"
        full["ProgName"] = "IVory"
        full["kLibUSBMuxVersion"] = 3
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: full, format: .xml, options: 0),
              send(fd, payload), let reply = receive(fd),
              let root = try? PropertyListSerialization.propertyList(from: reply, format: nil) else { return nil }
        return root as? [String: Any]
    }

    /// One request to the phone's lockdown service through a usbmuxd tunnel. Lockdown frames are a
    /// big-endian length and an XML plist, unlike usbmuxd's own little-endian header.
    private static func lockdown(_ device: Entry, _ message: [String: Any]) -> [String: Any]? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        let reply = exchange(fd, ["MessageType": "Connect", "DeviceID": device.id,
                                  "PortNumber": Int(lockdownPort.bigEndian)])
        guard (reply?["Number"] as? Int) == 0 else { return nil }
        var body = message
        body["Label"] = "IVory"
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) else {
            return nil
        }
        var header = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.append(contentsOf: $0) }
        guard writeAll(fd, header + payload), let head = readAll(fd, 4) else { return nil }
        let length = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length < 1 << 20, let data = readAll(fd, Int(length)),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return root as? [String: Any]
    }

    // MARK: - the socket

    private static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path)
        }
        let ok = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(fd); return nil }
        // A phone that is restarting or locked can leave a read hanging; the guide polls, so give up soon.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 16-byte header (length, version, message type, tag), then the plist.
    private static func send(_ fd: Int32, _ payload: Data) -> Bool {
        var header = Data()
        for value in [UInt32(16 + payload.count), version, plistMessage, UInt32(1)] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        return writeAll(fd, header + payload)
    }

    private static func receive(_ fd: Int32) -> Data? {
        guard let header = readAll(fd, 16) else { return nil }
        let total = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard total > 16, total < 8 << 20 else { return nil }   // a device list is never megabytes
        return readAll(fd, Int(total) - 16)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func readAll(_ fd: Int32, _ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return Data(buffer)
    }
}
