@_exported import struct Foundation.URL
@_exported import struct NIOSSL.TLSConfiguration

public struct MySQLConfiguration {
    public let address: () throws -> SocketAddress
    public let username: String
    public let password: String
    public let database: String?
    public let tlsConfiguration: TLSConfiguration?
    
    internal var _hostname: String?
    
    public init?(url: URL) {
        guard url.scheme == "mysql" else {
            return nil
        }
        guard let username = url.user else {
            return nil
        }
        guard let password = url.password else {
            return nil
        }
        guard let hostname = url.host else {
            return nil
        }
        guard let port = url.port else {
            return nil
        }
        
        let tlsConfiguration: TLSConfiguration?
        if url.query == "ssl=true" {
            tlsConfiguration = TLSConfiguration.forClient(certificateVerification: .none)
        } else {
            tlsConfiguration = nil
        }
        
        self.init(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: url.path.split(separator: "/").last.flatMap(String.init),
            tlsConfiguration: tlsConfiguration
        )
    }
    
    public init(
        hostname: String,
        port: Int = 3306,
        username: String,
        password: String,
        database: String? = nil,
        tlsConfiguration: TLSConfiguration? = nil
    ) {
        self.address = {
            return try SocketAddress.makeAddressResolvingHost(hostname, port: port)
        }
        self.username = username
        self.database = database
        self.password = password
        self.tlsConfiguration = tlsConfiguration
        self._hostname = hostname
    }
}

public struct MySQLConnectionSource: ConnectionPoolSource {
    public let configuration: MySQLConfiguration
    
    public init(configuration: MySQLConfiguration) {
        self.configuration = configuration
    }
    
    public func makeConnection(on eventLoop: EventLoop) -> EventLoopFuture<MySQLConnection> {
        let address: SocketAddress
        do {
            address = try self.configuration.address()
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        return MySQLConnection.connect(
            to: address,
            username: self.configuration.username,
            database: self.configuration.database ?? self.configuration.username,
            password: self.configuration.password,
            tlsConfiguration: self.configuration.tlsConfiguration,
            on: eventLoop
        )
    }
}

extension MySQLConnection: ConnectionPoolItem { }

extension MySQLRow: SQLRow {
    public func decode<D>(column: String, as type: D.Type) throws -> D where D : Decodable {
        guard let data = self.column(column) else {
            fatalError()
        }
        return try MySQLDataDecoder().decode(D.self, from: data)
    }
}

public struct SQLRaw: SQLExpression {
    public var string: String
    public init(_ string: String) {
        self.string = string
    }
    
    public func serialize(to serializer: inout SQLSerializer) {
        serializer.write(self.string)
    }
}

public struct MySQLDialect: SQLDialect {
    public init() {}
    
    public var identifierQuote: SQLExpression {
        return SQLRaw("`")
    }
    
    public var literalStringQuote: SQLExpression {
        return SQLRaw("'")
    }
    
    public mutating func nextBindPlaceholder() -> SQLExpression {
        return SQLRaw("?")
    }
    
    public func literalBoolean(_ value: Bool) -> SQLExpression {
        switch value {
        case false:
            return SQLRaw("0")
        case true:
            return SQLRaw("1")
        }
    }
    
    public var autoIncrementClause: SQLExpression {
        return SQLRaw("AUTO_INCREMENT")
    }
}

extension MySQLConnection: SQLDatabase { }

extension MySQLDatabase where Self: SQLDatabase {
    public func execute(sql query: SQLExpression, _ onRow: @escaping (SQLRow) throws -> ()) -> EventLoopFuture<Void> {
        var serializer = SQLSerializer(dialect: MySQLDialect())
        query.serialize(to: &serializer)
        return self.query(serializer.sql, serializer.binds.map { encodable in
            return try! MySQLDataEncoder().encode(encodable)
        }, onRow: { row in
            try! onRow(row)
        })
    }
}

extension ConnectionPool: SQLDatabase where Source.Connection: SQLDatabase {
    public func execute(sql query: SQLExpression, _ onRow: @escaping (SQLRow) throws -> ()) -> EventLoopFuture<Void> {
        return self.withConnection { $0.execute(sql: query, onRow) }
    }
}
