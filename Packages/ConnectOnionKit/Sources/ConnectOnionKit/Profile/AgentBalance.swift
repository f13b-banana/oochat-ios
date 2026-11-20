//
//  AgentBalance.swift
//  ConnectOnionKit
//
//  Created by Kevin Chin on 30/10/2026.
//

import Foundation

public enum AgentBalance {
    public static let lowThresholdUSD = 1.00

    public enum Notice: Equatable, Sendable {
        case low(usd: Double)
        case empty
    }

    public static func notice(for usd: Double?) -> Notice? {
        guard let usd, usd.isFinite else {
            return nil
        }
        if usd <= 0 {
            return .empty
        }
        if usd < lowThresholdUSD {
            return .low(usd: usd)
        }
        return nil
    }

    public static func message(for notice: Notice) -> String {
        switch notice {
        case .low(let usd):
            // Fixed locale, so a device set to France still shows $0.42 and not $0,42.
            let amount = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), usd)
            return "Running low \u{2014} $\(amount) left."
        case .empty:
            return "This agent is out of credits and will stop responding."
        }
    }

    // Add Credits Link
    public static func topUpURL(agentAddress: String) -> URL? {
        guard !agentAddress.isEmpty else {
            return nil
        }
        let unreserved = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._~")
        guard let value = agentAddress.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "o.openonion.ai"
        components.path = "/purchase"
        components.percentEncodedQuery = "key=\(value)"
        return components.url
    }
}
