import Crypto
import Foundation

extension MySQLConnection {
    /// Authenticates the `MySQLConnection`. This must be used before sending queries.
    ///
    /// - parameters:
    ///     - username: Username to login with.
    ///     - database: The database to select.
    ///     - password: Password for the user specified by `username`.
    /// - returns: A future that will complete when the authenticate is finished.
    public func authenticate(username: String, database: String, password: String? = nil, allowMultipleStatements: Bool = false) -> Future<Void> {
        var handshake: MySQLHandshakeV10?
        return send([]) { message in
            switch message {
            case .handshakev10(let _handshake):
                handshake = _handshake
                return true
            default: throw MySQLError(identifier: "handshake", reason: "Unsupported message encountered during handshake: \(message).", source: .capture())
            }
        }.flatMap(to: Void.self) {
            guard let handshake = handshake else {
                throw MySQLError(identifier: "handshake", reason: "Handshake required for auth response.", source: .capture())
            }
            let authPlugin = handshake.authPluginName
            let authResponse: Data
            switch authPlugin {
            case .some("mysql_native_password"), .none:
                guard handshake.capabilities.get(CLIENT_SECURE_CONNECTION) else {
                    throw MySQLError(identifier: "authproto", reason: "Pre-4.1 auth protocol is not supported or safe.", source: .capture())
                }
                guard let password = password else {
                    throw MySQLError(identifier: "password", reason: "Password required for auth plugin.", source: .capture())
                }
                guard handshake.authPluginData.count >= 20 else {
                    throw MySQLError(identifier: "salt", reason: "Server-supplied salt too short.", source: .capture())
                }
                let salt = Data(handshake.authPluginData[..<20])
                let passwordHash = try SHA1.hash(password)
                let passwordDoubleHash = try SHA1.hash(passwordHash)
                var hash = try SHA1.hash(salt + passwordDoubleHash)
                for i in 0..<20 {
                    hash[i] = hash[i] ^ passwordHash[i]
                }
                authResponse = hash
            default: throw MySQLError(identifier: "authPlugin", reason: "Unsupported auth plugin: \(authPlugin ?? "<none>")", source: .capture())
            }
            
            var capabilities: MySQLCapabilities = [
                CLIENT_PROTOCOL_41,
                CLIENT_PLUGIN_AUTH,
                CLIENT_SECURE_CONNECTION,
                CLIENT_CONNECT_WITH_DB,
                CLIENT_DEPRECATE_EOF,
            ]
            capabilities.set(CLIENT_MULTI_STATEMENTS, to: allowMultipleStatements)
            
            let response = MySQLHandshakeResponse41(
                capabilities: capabilities,
                maxPacketSize: 1_024,
                characterSet: 0x21,
                username: username,
                authResponse: authResponse,
                database: database,
                authPluginName: authPlugin ?? "<none>"
            )
            return self.send([.handshakeResponse41(response)]) { message in
                switch message {
                case .ok(_): return true
                default:
                    throw MySQLError(identifier: "handshake", reason: "Unsupported message encountered during handshake: \(message).", source: .capture())
                }
            }
        }
    }
}
