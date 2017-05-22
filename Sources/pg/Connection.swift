import Foundation


public final class Connection: NSObject, StreamDelegate {
	public enum Error: Swift.Error {
		case mismatchedDataLengths
		case unrecognizedMessage(UInt8)
		case malformedMessage
	}
	
	public enum MessageType: UInt8 {
		case authentication = 82 // R
		case statusReport = 83 // S
		case backendKeyData = 75 // K
		case readyForQuery = 90 // Z
		case rowDescription = 84 // T
		case commandComplete = 67 // C
		case dataRow = 68 // D
	}
	
	public enum RequestType: UInt8 {
		case startup // the only message that doesn't announce it's type
		
		case simpleQuery = 81 // Q
	}
	
	public enum AuthenticationResponse: UInt32 {
		case authenticationOK = 0
		// case kerberosV5 = 2
		// case cleartextPassword = 3
		// case MD5Password = 5
		// case SCMCredential = 6
	}
	
	public enum TransactionStatus: UInt8 {
		case notReady
		
		case idle = 73 // I - not in a transaction block
		case inTransaction = 84 // T
		case failed = 69 // E
	}
	
	
	// MARK: - Events
	
	public let connected = EventEmitter<Void>(name: "PG.Connection.connected")
	public let loginSuccess = EventEmitter<Void>(name: "PG.Connection.loginSuccess")
	
	public let readyForQuery = EventEmitter<TransactionStatus>(name: "PG.Connection.readyForQuery")
	
	public let rowDescriptionReceived = EventEmitter<[Field]>(name: "PG.Connection.rowDescriptionReceived")
	public let rowReceived = EventEmitter<[DataSlice?]>(name: "PG.Connection.rowReceived")
	public let commandComplete = EventEmitter<String>(name: "PG.Connection.commandComplete")
	
	
	// MARK: - Initialization
	
	private let queue = DispatchQueue(label: "PG.Connection", qos: .userInteractive)
	let input: InputStream
	let output: OutputStream
	
	init(input: InputStream, output: OutputStream) {
		self.input = input
		self.output = output
		
		super.init()
		
		input.delegate = self
		output.delegate = self
	}
	
	
	// MARK: - 
	
	public var isConnected: Bool {
		return self.input.streamStatus.isConnected && self.output.streamStatus.isConnected
	}
	
	public private(set) var isAuthenticated: Bool = false
	
	public private(set) var parameters: [String:String] = [:]
	
	public private(set) var processID: Int32?
	
	public private(set) var secretKey: Int32?
	
	public fileprivate(set) var transactionStatus: TransactionStatus = .notReady
	
	
	// MARK: - Writing
	
	struct WriteItem {
		let type: RequestType
		let buffer: Buffer
		let completion: (() -> Void)?
		
		var offset: Int = 0
		
		init(type: RequestType, buffer: Buffer, completion: (() -> Void)?) {
			self.type = type
			self.buffer = buffer
			self.completion = completion
		}
	}
	
	private var bufferQueue: [WriteItem] = []
	
	func write(_ type: RequestType, _ buffer: Buffer, completion: (() -> Void)? = nil) {
		queue.async {
			let writeItem = WriteItem(type: type, buffer: buffer, completion: completion)
			self.bufferQueue.append(writeItem)
			
			self.write()
		}
	}
	
	private func write() {
		if #available(OSX 10.12, *) {
			dispatchPrecondition(condition: .onQueue(self.queue))
		}
		
		while output.hasSpaceAvailable {
			guard let current = bufferQueue.first else { return }
			bufferQueue.removeFirst()
			
			print("writing: \(current.type) \(current.buffer.data)")
			if current.type != .startup {
				output.write(current.type.rawValue)
			}
			
			output.write(UInt32(current.buffer.data.count + 4))
			output.write(current.buffer.data)
			current.completion?()
		}
	}
	
	
	// MARK: - Reading
	
	private func read() {
		if #available(OSX 10.12, *) {
			dispatchPrecondition(condition: .onQueue(self.queue))
		}
		
		do {
			guard input.hasBytesAvailable else { return }
			
			
			let byte: UInt8 = try input.read()
			print("command: \(byte)")
			
			let length: UInt32 = try input.read() - 4
			var buffer = ReadBuffer(input.read(Int(length)))
			guard buffer.data.count == Int(length) else { throw Error.mismatchedDataLengths }
			
			guard let messageType = MessageType(rawValue: byte) else {
				print("unrecognizedMessage: \(byte)")
				throw Error.unrecognizedMessage(byte)
			}
			
			
			switch messageType {
			case .authentication:
				let rawResponse: UInt32 = try buffer.read()
				
				if let response = AuthenticationResponse(rawValue: rawResponse) {
					switch response {
					case .authenticationOK:
						self.isAuthenticated = true
						self.loginSuccess.emit()
					}
				} else {
					
				}
			case .statusReport:
				let key: String = try buffer.read()
				let value: String = try buffer.read()
				
				parameters[key] = value
				
				print("status \(key): \(value)")
			case .backendKeyData:
				guard buffer.data.count == 8 else { throw Error.malformedMessage }
				self.processID = try buffer.read()
				self.secretKey = try buffer.read()
				
				print("processID: \(processID!) secretKey: \(secretKey!)")
			case .readyForQuery:
				guard buffer.data.count == 1 else { throw Error.malformedMessage }
				
				let rawStatus: UInt8 = try buffer.read()
				self.transactionStatus = TransactionStatus(rawValue: rawStatus) ?? .idle
				
				self.readyForQuery.emit(self.transactionStatus)
			case .rowDescription:
				let fieldsCount: UInt16 = try buffer.read()
				
				let fields: [Field] = try (0..<fieldsCount).map() { _ in
					let field = Field()
					field.name = try buffer.read()
					field.tableID = try buffer.read()
					field.columnID = try buffer.read()
					field.dataTypeID = try buffer.read()
					field.dataTypeSize = try buffer.read()
					field.dataTypeModifier = try buffer.read()
					field.mode = try Field.Mode(rawValue: buffer.read()) ?? .text
					return field
				}
				
				self.rowDescriptionReceived.emit(fields)
				print("fields: \(fields)")
			case .commandComplete:
				let commandTag = try buffer.read() as String
				print("command complete: \(commandTag)")
				
				self.commandComplete.emit(commandTag)
			case .dataRow:
				let columnCount = try buffer.read() as UInt16
				print("columnCount: \(columnCount)")
				
				let rows: [DataSlice?] = try (0..<columnCount).map() { _ in
					let length = try buffer.read() as Int32
					print("length: \(length)")
					if length >= 0 {
						return try buffer.read(length: Int(length))
					} else {
						return nil
					}
				}
				
				self.rowReceived.emit(rows)
				let textRows = rows.flatMap({$0}).map({ String(bytes: $0, encoding: .utf8) })
				print("rows: \(textRows)")
			}
		} catch {
			print("read error: \(error)")
		}
	}
	
	
	// MARK: - StreamDelegate
	
	public func stream(_ stream: Stream, handle eventCode: Stream.Event) {
		queue.async {
			switch eventCode {
			case Stream.Event.openCompleted:
				print("openCompleted \(stream)")
				if self.isConnected {
					self.connected.emit()
				}
			case Stream.Event.hasBytesAvailable:
				print("hasBytesAvailable")
				self.read()
			case Stream.Event.hasSpaceAvailable:
				print("hasSpaceAvailable")
				self.write()
			case Stream.Event.errorOccurred:
				print("errorOccurred: \(stream.streamError!) \(stream)")
			case Stream.Event.endEncountered:
				print("endEncountered \(stream)")
			default:
				print("invalid event \(stream)")
				break
			}
		}
	}
}

extension Connection {
	func sendStartup(user: String, database: String?) {
		var message = Buffer()
		
		// protocol version
		message.write(3 as Int16)
		message.write(0 as Int16)
		
		message.write("user")
		message.write(user)
		
		if let database = database {
			print("database: \(database)")
			message.write("database")
			message.write(database)
		}
		
		message.write("client_encoding")
		message.write("'utf-8'")
		
		message.write("")
		
		self.write(.startup, message)
	}
	
	func simpleQuery(_ query: String) {
		self.transactionStatus = .notReady
		
		var message = Buffer()
		message.write(query)
		
		self.write(.simpleQuery, message)
	}
}
