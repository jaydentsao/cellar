import Foundation

// MARK: - Graphics

enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Hashable {
    case wined3d
    case wined3dVulkan
    case dxvk
    case dxmt
    case d3dmetal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wined3d: return "WineD3D (OpenGL)"
        case .wined3dVulkan: return "WineD3D (Vulkan → Metal)"
        case .dxvk: return "DXVK (Vulkan via MoltenVK)"
        case .dxmt: return "DXMT (Direct3D 11 → Metal)"
        case .d3dmetal: return "D3DMetal (engine-provided)"
        }
    }

    var detail: String {
        switch self {
        case .wined3d:
            return "Wine's built-in Direct3D. Most compatible, slowest. Good for older DirectX 9 games."
        case .wined3dVulkan:
            return "Wine's built-in Direct3D on its Vulkan renderer, which MoltenVK turns into Metal. Gives DirectX 10/11 on a stock Wine engine with nothing extra to install, as long as the engine bundles MoltenVK."
        case .dxvk:
            return "Translates DirectX 9/10/11 to Vulkan, then MoltenVK to Metal. Needs a macOS DXVK build installed into this bottle."
        case .dxmt:
            return "Open-source Direct3D 10/11 → Metal layer, the one CrossOver also ships. Best choice for modern DirectX 11 games such as Deadlock. Has to be installed into the Wine engine first."
        case .d3dmetal:
            return "Apple's DirectX 11/12 → Metal layer. Only works with an engine that ships it (for example Apple's Game Porting Toolkit build)."
        }
    }
}

// MARK: - Windows version

enum WindowsVersion: String, Codable, CaseIterable, Identifiable, Hashable {
    case win11, win10, win81, win8, win7, winxp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win8: return "Windows 8"
        case .win7: return "Windows 7"
        case .winxp: return "Windows XP"
        }
    }
}

// MARK: - Small value types

struct EnvVar: Codable, Identifiable, Hashable {
    var id = UUID()
    var key: String
    var value: String
}

struct Program: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Absolute macOS path to the .exe (or .msi/.bat/.lnk) inside or outside the bottle.
    var path: String
    var arguments: String = ""
}

// MARK: - Bottle

/// Everything you control about a bottle. Stored as cellar.json inside the bottle folder.
struct BottleConfig: Codable, Hashable {
    var name: String
    var enginePath: String
    var windowsVersion: WindowsVersion = .win10
    var graphics: GraphicsBackend = .wined3d
    var msync: Bool = true
    var esync: Bool = false
    var metalHUD: Bool = false
    var dxvkHUD: String = ""
    var retinaMode: Bool = false
    var wineDebug: String = "-all"
    /// Extra WINEDLLOVERRIDES, e.g. "winmm=n,b;xinput1_3=n".
    var dllOverrides: String = ""
    var environment: [EnvVar] = []
    var programs: [Program] = []
    var created: Date = Date()
}

/// A bottle is a folder that is both a Wine prefix (WINEPREFIX) and the home of its cellar.json.
struct Bottle: Identifiable, Hashable {
    static let configFileName = "cellar.json"

    let url: URL
    var config: BottleConfig

    var id: URL { url }
    var configURL: URL { url.appendingPathComponent(Bottle.configFileName) }
    var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
    var isInitialized: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }
}

enum CellarError: LocalizedError {
    case wine(String)
    case dxvk(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .wine(let m), .dxvk(let m), .io(let m): return m
        }
    }
}

extension JSONEncoder {
    static var cellar: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var cellar: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Splits a launch-argument string the way a shell would for simple cases:
/// spaces separate arguments, single or double quotes group them.
func splitArguments(_ s: String) -> [String] {
    var out: [String] = []
    var current = ""
    var quote: Character? = nil
    var hasToken = false
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            hasToken = true
        } else if ch == " " || ch == "\t" {
            if hasToken {
                out.append(current)
                current = ""
                hasToken = false
            }
        } else {
            current.append(ch)
            hasToken = true
        }
    }
    if hasToken { out.append(current) }
    return out
}
