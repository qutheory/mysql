import Async
import Bits

enum StreamState {
    // Authenticating
    case start, sentSSL, sentHandshake, sentAuthentication
    
    // Idle states
    case nothing, closed
    
    struct QueryContext {
        let output: AnyInputStream<Row>
        let binary: UInt32?
    }
    
    case columnCount(QueryContext)
    case columns(Int, QueryContext)
    case rows(QueryContext)
    
    case preparing(callback: (PreparedStatement) -> ())
    case preparingParameters(UInt32, [Field], UInt16, UInt16, callback: (PreparedStatement) -> ())
    case preparingColumns(UInt32, [Field], [Field], UInt16, callback: (PreparedStatement) -> ())
    case resettingPreparation
}

final class MySQLStateMachine: ConnectionContext {
    typealias Input = Task
    typealias Output = Packet
    
    let user: String
    let password: String?
    let database: String
    
    var state: StreamState {
        didSet {
            if case .nothing = state {
                self.columns = nil
                self.unprocessedPacket = nil
                self.downstreamDemand = 0
                executor.request()
            }
        }
    }
    
    /// The inserted ID from the last successful query
    public var lastInsertID: UInt64?
    
    /// Amount of affected rows in the last successful query
    public var affectedRows: UInt64?
    
    var handshake: Handshake?
    var sequenceId: UInt8
    var ssl: MySQLSSLConfig?
    var connected = Promise<Void>()
    var worker: Worker
    let parser: TranslatingStreamWrapper<MySQLPacketParser>
    let executor: PushStream<Task>
    let serializer: PushStream<Packet>
    let _serializer: MySQLPacketSerializer
    var downstreamDemand: UInt
    var unprocessedPacket: Packet?
    
    var columns: [Field]?
    
    init<S>(
        source: SocketSource<S>,
        sink: SocketSink<S>,
        user: String,
        password: String?,
        database: String,
        ssl: MySQLSSLConfig?,
        worker: Worker
    ) {
        self.state = .start
        self.parser = MySQLPacketParser().stream(on: worker)
        self.ssl = ssl
        self.sequenceId = 0
        self.worker = worker
        self.serializer = PushStream<Packet>()
        self.executor = PushStream<Task>()
        self._serializer = MySQLPacketSerializer()
        self.user = user
        self.password = password
        self.database = database
        self.downstreamDemand = 0

        source.stream(to: parser).drain { packet, upstream in
            do {
                try self.parse(packet: packet, upstream: upstream)
            } catch {
                self.error(error)
            }
        }.upstream?.request()
        
        self.serializer.stream(to: _serializer.stream(on: worker)).output(to: sink)
        
        self.executor.drain { task, _ in
            try self.process(task: task)
        }.upstream?.request()
    }
    
    func error(_ error: Error) {
        switch state {
        case .columnCount(let context):
            self.state = .nothing
            context.output.error(error)
        case .columns(_, let context):
            self.state = .nothing
            context.output.error(error)
        case .rows(let context):
            self.state = .nothing
            context.output.error(error)
        default: break
        }
    }
    
    func parse(packet: Packet, upstream: ConnectionContext) throws {
        switch state {
        case .start:
            // https://mariadb.com/kb/en/library/1-connecting-connecting/
            if  let ssl = self.ssl, capabilities.contains(.ssl) {
                _ = ssl
                fatalError("Unsupported StartTLS")
            } else {
                state = .sentHandshake
                serializer.push(try doHandshake(from: packet))
                upstream.request()
            }
        case .sentSSL:
            // https://mariadb.com/kb/en/library/1-connecting-connecting/
            state = .sentHandshake
            serializer.push(try doHandshake(from: packet))
        case .sentHandshake:
            // https://mariadb.com/kb/en/library/1-connecting-connecting/
            
            guard let packet = try self.finishAuthentication(for: packet) else {
                state = .nothing
                self.connected.complete()
                return
            }
            
            state = .sentAuthentication
            serializer.push(packet)
        case .sentAuthentication:
            state = .nothing
            _ = try packet.parseBinaryOK()
        case .nothing:
            throw MySQLError(.unexpectedResponse)
        case .closed:
            throw MySQLError(.unexpectedResponse)
        case .columnCount(let context):
            if context.binary != nil {
                // Ignore EOF
                if packet.payload.first == 0xfe, packet.payload.count == 5 {
                    upstream.request()
                    return
                }
            }
            
            var parser = Parser(packet: packet)
            let length = try parser.parseLenEnc()
            
            guard length < Int.max else {
                throw MySQLError(.unexpectedResponse)
            }
            
            if length == 0 {
                defer {
                    self.cancel()
                    context.output.close()
                    self.executor.request()
                }
                if let (affectedRows, lastInsertID) = try packet.parseBinaryOK() {
                    self.affectedRows = affectedRows
                    self.lastInsertID = lastInsertID
                }
                
                return
            }
            
            state = .columns(numericCast(length), context)
            upstream.request()
        case .columns(let columnCount, let context):
            if packet.payload.first == 0xfe {
                let eof = try EOF(packet: packet)
                
                if eof.flags & EOF.serverMoreResultsExists == 0 {
                    self.cancel()
                    context.output.close()
                    return
                }
                
                upstream.request()
                return
            }
            
            if self.columns == nil {
                self.columns = []
            }
            
            self.columns?.append(try packet.parseFieldDefinition())
            
            if self.columns?.count == columnCount {
                self.state = .rows(context)
            }
            
            upstream.request()
        case .rows(let context):
            guard let columns = self.columns else {
                throw MySQLError(identifier: "row-columns", reason: "The rows were being parsed but no columns were found")
            }
            
            // End of Rows
            if packet.payload.first == 0xfe {
                guard let (affectedRows, lastInsertID) = try packet.parseBinaryOK() else {
                    upstream.request()
                    return
                }
                
                self.affectedRows = affectedRows
                self.lastInsertID = lastInsertID
                
                self.cancel()
                context.output.close()
                self.executor.request()
                return
            }
            
            if downstreamDemand > 0 {
                downstreamDemand -= 1
                let row = try packet.parseRow(columns: columns)
                context.output.next(row)
                upstream.request()
            } else {
                unprocessedPacket = packet
            }
        case .preparing(let callback):
            guard packet.payload.first == 0x00, packet.payload.count == 12 else {
                throw MySQLError(packet: packet)
            }
            
            var parser = Parser(packet: packet, position: 1)
            
            let id = try parser.parseUInt32()
            let columns = try parser.parseUInt16()
            let parameters = try parser.parseUInt16()
            
            if parameters > 0 {
                self.state = .preparingParameters(id, [], parameters, columns, callback: callback)
                upstream.request()
            } else if columns > 0 {
                self.state = .preparingColumns(id, [], [], columns, callback: callback)
                upstream.request()
            } else {
                let statement = PreparedStatement(statementID: id, columns: [], stateMachine: self, parameters: [])
                self.cancel()
                callback(statement)
            }
        case .preparingParameters(let id, var parameters, let paramCount, let columnCount, let callback):
            if packet.payload.first == 0xfe, packet.payload.count == 5 {
                upstream.request()
                return
            }
            
            let field = try packet.parseFieldDefinition()
            parameters.append(field)
            
            if parameters.count == paramCount {
                if columnCount > 0 {
                    self.state = .preparingColumns(id, parameters, [], columnCount, callback: callback)
                    upstream.request()
                } else {
                    let statement = PreparedStatement(statementID: id, columns: [], stateMachine: self, parameters: parameters)
                    self.cancel()
                    callback(statement)
                    return
                }
            } else {
                self.state = .preparingParameters(id, parameters, paramCount, columnCount, callback: callback)
                upstream.request()
            }
        case .preparingColumns(let id, let parameters, var columns, let columnCount, let callback):
            if packet.payload.first == 0xfe, packet.payload.count == 5 {
                upstream.request()
                return
            }
            
            let field = try packet.parseFieldDefinition()
            columns.append(field)
            
            if columns.count == columnCount {
                let statement = PreparedStatement(statementID: id, columns: columns, stateMachine: self, parameters: parameters)
                self.cancel()
                callback(statement)
            } else {
                self.state = .preparingColumns(id, parameters, columns, columnCount, callback: callback)
                upstream.request()
            }
        case .resettingPreparation:
            defer {
                self.state = .nothing
            }
            
            guard packet.payload.first == 0x00 else {
                throw MySQLError(packet: packet)
            }
        }
    }
    
    func connection(_ event: ConnectionEvent) {
        switch event {
        case .cancel:
            state = .nothing
            downstreamDemand = 0
        case .request(let amount):
            if amount == .max {
                self.downstreamDemand = .max
            } else {
                downstreamDemand += amount
            }
            
            // If data is being awaited
            if let packet = self.unprocessedPacket {
                do {
                    try self.parse(packet: packet, upstream: self.parser)
                } catch {
                    self.error(error)
                }
            }
        }
    }
    
    fileprivate func process(task: Task) throws {
        guard let packet = task.packet else {
            return
        }
        
        self.state = makeState(for: task)
        
        serializer.next(packet)
        parser.request()
    }
    
    func close(immediately: Bool = false) {
        if immediately {
            self.state = .closed
            self.serializer.close()
        } else {
            // Write `close`
            _ = send(.close)
            
            executor.close()
        }
    }
    
    func send(_ task: Task) {
        self.executor.next(task)
    }
    
    fileprivate func completeTask() {
        self.state = .nothing
        self.executor.request()
    }
    
    fileprivate func makeState(for task: Task) -> StreamState {
        switch task {
        case .close:
            return .closed
        case .textQuery(_, let stream):
            let context = StreamState.QueryContext(output: stream, binary: nil)
            stream.connect(to: self)
            self.request()
            
            return .columnCount(context)
        case .none:
            return .nothing
        case .prepare(_, let callback):
            return .preparing(callback: callback)
        case .closePreparation(_):
            return .nothing
        case .resetPreparation(_):
            return .resettingPreparation
        case .executePreparation(_, let context):
            context.output.connect(to: self)
            self.request()
            return .columnCount(context)
        case .getMore(_, let context):
            context.output.connect(to: self)
            self.request()
            return .rows(context)
        }
    }
}

struct EOF {
    var flags: UInt16
    
    static let serverMoreResultsExists: UInt16 = 0x0008
    
    init(packet: Packet) throws {
        var parser = Parser(packet: packet)
        
        guard try parser.byte() == 0xfe, packet.payload.count == 5 else {
            throw MySQLError(.invalidPacket)
        }
        
        self.flags = try parser.parseUInt16()
    }
}
