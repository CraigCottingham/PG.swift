import Foundation


public class StreamSocket: NSObject, Socket {
	fileprivate let queue = DispatchQueue(label: "StreamSocket")
	
	public let input: InputStream
	public let output: OutputStream
	
	public init?(host: String, port: Int) {
		var input: InputStream?
		var output: OutputStream?
		Stream.getStreamsToHost(withName: host, port: port, inputStream: &input, outputStream: &output)
		
		if let input = input, let output = output {
			self.input = input
			self.output = output
		} else {
			return nil
		}
	}
	
	
	// MARK: - Events
	
	/// Emitted when the connection is established with the server
	public let connected = EventEmitter<Void>(name: "PG.StreamSocket.connected")
	fileprivate var hasEmittedConnected = false
	
	
	// MARK: - Connection
	
	/// If the connection has been established
	public var isConnected: Bool {
		return self.input.streamStatus.isConnected && self.output.streamStatus.isConnected
	}
	
	public func connect() {
		for stream in [input, output] {
			stream.delegate = self
			stream.schedule(in: .current, forMode: .defaultRunLoopMode)
			stream.open()
		}
	}
	
	
	// MARK: - Writing
	
	struct WriteItem {
		let data: Data
		let completion: (() -> Void)?
	}
	
	private var writeQueue: [WriteItem] = []
	
	public func write(data: Data, completion: (() -> Void)? = nil) {
		queue.async {
			let item = WriteItem(data: data, completion: completion)
			self.writeQueue.append(item)
			
			self.performWrite()
		}
	}
	
	fileprivate func performWrite() {
		if #available(OSX 10.12, *) {
			dispatchPrecondition(condition: .onQueue(self.queue))
		}
		
		while output.hasSpaceAvailable {
			guard let current = writeQueue.first else { return }
			writeQueue.removeFirst()
			
			output.write(current.data)
			current.completion?()
		}
	}
	
	
	// MARK: - Reading
	
	struct ReadRequest {
		let length: Int
		let completion: ((Data) -> Void)?
	}
	
	private var readQueue: [ReadRequest] = []
	
	public func read(length: Int, completion: ((Data) -> Void)?) {
		queue.async {
			let request = ReadRequest(length: length, completion: completion)
			self.readQueue.append(request)
			
			self.performRead()
		}
	}
	
	fileprivate func performRead() {
		if #available(OSX 10.12, *) {
			dispatchPrecondition(condition: .onQueue(self.queue))
		}
		
		while input.hasBytesAvailable {
			guard let current = readQueue.first else { return }
			readQueue.removeFirst()
			
			guard let data = input.read(current.length) else { return } // TODO: handle this more gracefully
			current.completion?(data)
		}
	}
}


extension StreamSocket: StreamDelegate {
	public func stream(_ stream: Stream, handle eventCode: Stream.Event) {
		queue.async {
			switch eventCode {
			case Stream.Event.openCompleted:
//				print("openCompleted \(stream)")
				if self.isConnected && !self.hasEmittedConnected {
					self.hasEmittedConnected = true
					self.connected.emit()
				}
			case Stream.Event.hasBytesAvailable:
//				print("hasBytesAvailable")
				self.performRead()
			case Stream.Event.hasSpaceAvailable:
//				print("hasSpaceAvailable")
				self.performWrite()
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