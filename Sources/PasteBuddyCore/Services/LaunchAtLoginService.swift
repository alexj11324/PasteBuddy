import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

public enum LaunchAtLoginError: LocalizedError, Equatable {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Launch at login is not available in this build."
        }
    }
}

public enum LaunchAtLoginService {
    public static var isAvailable: Bool {
        #if canImport(ServiceManagement)
        true
        #else
        false
        #endif
    }

    public static func setEnabled(_ isEnabled: Bool) throws {
        #if canImport(ServiceManagement)
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        #else
        throw LaunchAtLoginError.unavailable
        #endif
    }
}
