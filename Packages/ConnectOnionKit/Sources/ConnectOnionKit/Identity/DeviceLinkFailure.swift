import dnssd
import Foundation
import Network

/// Why a Device Link failed, in the person's terms, with what to do next. All link failure copy lives here.
public enum DeviceLinkFailure: Error, Equatable, Sendable {
    case expired
    case notOnSameNetwork
    /// The giver turned the code away, which used it up.
    case wrongCode
    /// The entered code isn't a code for this link, caught before connecting; the other device's code still works.
    case mistypedCode
    case cancelledOnOtherDevice
    case localNetworkDenied
    /// This device could not store the Identity it accepted; its own Identity is unchanged.
    case couldNotSave
    /// Anything else, including a sealed Identity that failed its checks.
    case other

    public init(_ error: any Error) {
        switch error {
        case let error as DeviceLinkFailure:
            self = error
        case let error as DeviceLinkError:
            switch error {
            case .expired, .reused: self = .expired
            case .wrongCode: self = .wrongCode
            case .cancelled: self = .cancelledOnOtherDevice
            // A code refused before connecting is reported as `.mistypedCode` by the flow itself; a
            // malformed message after that may have used the code up, so it doesn't promise it still works.
            case .malformed, .tampered, .addressMismatch, .noIdentity: self = .other
            }
        // Bonjour reports a refused local-network permission as a DNS-SD policy error. Any other
        // DNS-SD or socket error means the other device could not be found or reached.
        case NWError.dns(let code) where code == kDNSServiceErr_PolicyDenied:
            self = .localNetworkDenied
        case NWError.dns, NWError.posix:
            self = .notOnSameNetwork
        default:
            self = .other
        }
    }

    public var title: String {
        switch self {
        case .expired: "This code has expired"
        case .notOnSameNetwork: "Couldn't find the other device"
        case .wrongCode: "That code didn't work"
        case .mistypedCode: "That isn't a code for this link"
        case .cancelledOnOtherDevice: "The link was cancelled on the other device"
        case .localNetworkDenied: "Local network access is off"
        case .couldNotSave: "Couldn't save the identity on this device"
        case .other: "Couldn't link your devices"
        }
    }

    /// What the person can do about it.
    public var nextStep: String {
        switch self {
        case .expired:
            "A code works once and lasts two minutes. Make a new code and try again."
        case .notOnSameNetwork:
            "Connect both devices to the same Wi-Fi network, check the Link Code, then try again."
        case .wrongCode:
            "A code works for one try. Make a new code on the device showing it, and enter that one."
        case .mistypedCode:
            "Check the Link Code shown on the other device and enter it again."
        case .cancelledOnOtherDevice:
            "Start the link again on both devices when you're ready."
        case .localNetworkDenied:
            #if os(macOS)
            "Turn on this app in System Settings › Privacy & Security › Local Network, then try again."
            #else
            "Turn on this app in Settings › Privacy & Security › Local Network, then try again."
            #endif
        case .couldNotSave:
            "This device kept its current identity. Make a new code and try again."
        case .other:
            "Make a new code and try again."
        }
    }
}
