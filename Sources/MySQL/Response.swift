import Foundation

enum Response {
    struct State {
        let marker: UInt8
        let state: (UInt8, UInt8, UInt8, UInt8, UInt8)
    }
    
    var error: Error? {
        if case .error(let error) = self {
            return error
        }
        
        return nil
    }
    
    struct Error : Swift.Error {
        let code: UInt16
        let state: State?
        let message: String
    }
    
    case error(Error)
    
    struct OK {
        let affectedRows: UInt64
        let lastInsertId: UInt64
        let status: UInt16?
        let warnings: UInt16?
        let data: Data
    }
    
    case ok(OK)
    case eof(OK)
}

extension Packet {
    var isResponse: Bool {
        return payload.count > 0 && (payload[0] == 0xff || payload[0] == 0xfe || payload[0] == 0x00)
    }
    
    func parseResponse(mysql41: Bool) throws -> Response {
        guard self.payload.count > 0 else {
            throw MySQLError.invalidResponse
        }
        
        switch self.payload[0] {
        case 0xff:
            guard self.payload.count > 3 else {
                throw MySQLError.invalidResponse
            }
            
            let code = (UInt16(payload[1]) << 8) | UInt16(payload[2])
            
            if mysql41 {
                guard self.payload.count > 10 else {
                    throw MySQLError.invalidResponse
                }
                
                let state = Response.State(
                    marker: payload[3],
                    state: (payload[4], payload[5], payload[6], payload[7], payload[8])
                )
                
                let message = String(bytes: payload[9..<payload.endIndex], encoding: .utf8) ?? ""
                
                return .error(Response.Error(code: code, state: state, message: message))
            } else {
                let message = String(bytes: payload[3..<payload.endIndex], encoding: .utf8) ?? ""
                
                return .error(Response.Error(code: code, state: nil, message: message))
            }
        case 0x00:
            fallthrough
        case 0xfe:
            guard self.payload.count > 3 else {
                throw MySQLError.invalidResponse
            }
            
            let parser = Parser(packet: self, position: 1)
            
            let affectedRows = try parser.parseLenEnc()
            let lastInsertedId = try parser.parseLenEnc()
            let statusFlags: UInt16?
            let warnings: UInt16?
            
            if mysql41 {
                statusFlags = try parser.parseUInt16()
                warnings = try parser.parseUInt16()
                
                // TODO: CLIENT_SESSION_TRACK
                // TODO: SERVER_SESSION_STATE_CHANGED
            } else {
                statusFlags = nil
                warnings = nil
            }
            
            // TODO: Client transactions
            
            let data = Data(self.payload[parser.position..<self.payload.endIndex])
            let ok = Response.OK(affectedRows: affectedRows, lastInsertId: lastInsertedId, status: statusFlags, warnings: warnings, data: data)
            
            if data.count > 0 {
                return .ok(ok)
            } else {
                return .eof(ok)
            }
        default:
            throw MySQLError.invalidResponse
        }
    }
}
