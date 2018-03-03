import Debugging

public struct MySQLError : Swift.Error, Debuggable {
    public var possibleCauses: [String] {
        switch problem {
        case .invalidCredentials:
            return [
                "The username, database and/or password was invalid."
            ]
        case .connectionInUse:
            return [
                "The connection is already being used by another query."
            ]
        default:
            return []
        }
    }
    
    public var suggestedFixes: [String] {
        switch problem {
        case .invalidCredentials:
            return [
                "If you're not using a password on this user, set the password to `nil`, rather than an empty string (\"\")"
            ]
        case .connectionInUse:
            return [
                "If you're manually managing your connections, ensure a single connection is not used for more than one query at a time.",
                "If you're not managing connections yourself and are using the ConnectionPool instead, please file a bug report."
            ]
        default:
            return []
        }
    }
    
    /// A description of the problem
    public var reason: String {
        switch problem {
        case .invalidQuery(let code, let message):
            return "MySQL error \(code) \(message)"
        case .invalidPacket:
            return "The received packet was invalid"
        case .invalidHandshake:
            return "The server's handshake was invalid"
        case .invalidResponse:
            return "The packet could not be parsed into a valid response"
        case .unsupported:
            return "This feature is not (yet) supported"
        case .parsingError:
            return "The binary format was not successfully parsed"
        case .decodingError:
            return "The received data did not correctly decode into a `Decodable`"
        case .connectionInUse:
            return "Connections can't be used twice at the same time. Communicate using a separate connection or though the connection pool instead."
        case .unexpectedResponse: return "The server responded an unexpected response which could not be matched to an action"
        case .invalidCredentials:
            return "Authentication was not successful"
        case .other(_, let reason): return reason
        case .invalidTypeBound(let got, let expected):
            return "Field of type `\(got)` was bound, mismatching the expected type `\(expected)`"
        case.tooManyParametersBound:
            return "More parameters were bound than specified in the query"
        case .notEnoughParametersBound:
            return "Not enough parameters were bound to match the parameter count of this query"
        case .invalidBinding(_):
            return "A type was bound that didn't match the expectation"
        }
    }
    
    /// How we got to this problem
    public var stackTrace: [String]
    
    /// The problem's unique identifier
    public var identifier: String {
        return self.problem.rawValue
    }
    
    /// Creates a new problem
    init(
        _ problem: Problem,
        source: SourceLocation
    ) {
        self.stackTrace = MySQLError.makeStackTrace()
        self.sourceLocation = source
        self.problem = problem
    }
    
    init(
        packet: Packet,
        source: SourceLocation
    ) {
        self.stackTrace = MySQLError.makeStackTrace()
        self.sourceLocation = source
        
        var parser = Parser(packet: packet, position: 1)
        
        do {
            let code = try parser.parseUInt16()
                
            if code != 0xffff {
                if parser.packet.payload.first == .numberSign {
                    // SQL State
                    parser.position += 5
                }
                
                guard
                    parser.position < parser.payload.count,
                    let message = String(bytes: parser.payload[parser.position...], encoding: .utf8)
                else {
                    self.problem = .decodingError
                    return
                }
                
                self.problem = .invalidQuery(code, message)
            } else {
                self.problem = .invalidQuery(code, "")
            }
        } catch {
            self.problem = .decodingError
        }
    }
    
    init(
        identifier: String,
        reason: String,
        sourceLocation: SourceLocation
    ) {
        self.problem = .other(identifier: identifier, reason: reason)
        self.stackTrace = MySQLError.makeStackTrace()
        self.sourceLocation = sourceLocation
    }
    
    /// The location in Swift code this error originated from
    public let sourceLocation: SourceLocation?
    
    /// Which problem
    internal let problem: Problem
    
    /// The problem
    enum Problem {
        var rawValue: String {
            switch self {
            case .other(let identifier, _): return identifier
            case .invalidQuery(_): return "invalidQuery"
            case .invalidPacket: return "invalidPacket"
            case .invalidHandshake: return "invalidHandshake"
            case .invalidResponse: return "invalidResponse"
            case .unsupported: return "unsupported"
            case .parsingError: return "parsingError"
            case .decodingError: return "decodingError"
            case .connectionInUse: return "connectionInuse"
            case .invalidCredentials: return "invalidCredentials"
            case .tooManyParametersBound: return "tooManyParametersBound"
            case .unexpectedResponse: return "unexpectedResponse"
            case .notEnoughParametersBound: return "notEnoughParametersBound"
            case .invalidTypeBound(_, _): return "invalidTypeBound"
            case .invalidBinding(_): return "invalidBinding"
            }
        }
        
        case invalidTypeBound(got: PseudoType, expected: Field.FieldType)
        case invalidQuery(UInt16, String)
        case other(identifier: String, reason: String)
        case invalidPacket
        case invalidHandshake
        case invalidResponse
        case unsupported
        case parsingError
        case unexpectedResponse
        case decodingError
        case connectionInUse
        case invalidCredentials
        case invalidBinding(for: Field.FieldType)
        case notEnoughParametersBound
        case tooManyParametersBound
    }
}
