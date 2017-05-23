import Foundation


public class QueryResult {
	public enum Error: Swift.Error {
		case invalidCommandResponse
		case mismatchedRowCount
	}
	
	public enum Kind: String {
		case insert
		case delete
		case update
		case select
		case move
		case fetch
		case copy
	}
	
	public let kind: Kind
	public let fields: [Field]
	public let rows: [Row]
	public let rowCount: Int
	public let typeParser: TypeParser
	
	init(commandResponse: String, fields: [Field], rows: [[DataSlice?]], typeParser: TypeParser) throws {
		let responseComponents = commandResponse.components(separatedBy: " ")
		guard
			responseComponents.count >= 2,
			let kind = Kind(rawValue: responseComponents[0].lowercased()),
			let rowCount = Int(responseComponents[1])
		else { throw Error.invalidCommandResponse }
		
		if kind == .select {
			guard rowCount == rows.count else { throw Error.mismatchedRowCount }
		}
		
		self.kind = kind
		self.fields = fields
		self.rowCount = rowCount
		self.typeParser = typeParser
		self.rows = rows.map({ Row(fields: fields, typeParser: typeParser, rawRow: $0) })
	}
	
	
	
	public struct Row {
		public let fields: [Field]
		public let typeParser: TypeParser
		let rawRow: [DataSlice?]
		
		public subscript(raw index: Int) -> DataSlice? {
			get {
				return rawRow[index]
			}
		}
		
		public subscript(index: Int) -> Any? {
			get {
				guard let data = rawRow[index] else { return nil }
				let field = fields[index]
				
				return typeParser.parse(data, for: field)
			}
		}
		
		public subscript(raw name: String) -> DataSlice? {
			guard let index = fields.index(where: { $0.name == name }) else { return nil }
			
			return rawRow[index]
		}
		
		public subscript(name: String) -> Any? {
			guard let index = fields.index(where: { $0.name == name }) else { return nil }
			
			return self[index]
		}
		
		/// Get a value for a given column as a specific type
		///
		/// some types can handle multiple postgres types (like Int for all sizes of pg ints). Using this method, it can return the result as a specific type, assuming it is compatable with the column type.
		public func value<T: PostgresRepresentable>(at index: Int) -> T? {
			// swift 4 should introduce generic subscripts
			guard let data = rawRow[index] else { return nil }
			let field = fields[index]
			
			return typeParser.parse(data, for: field)
		}
		
		public func value<T: PostgresRepresentable>(for name: String) -> T? {
			guard let index = fields.index(where: { $0.name == name }) else { return nil }
			
			return value(at: index)
		}
	}
}


extension Dictionary where Key == String, Value == Any {
	public init(_ row: QueryResult.Row) {
		self.init()
		
		for (index, field) in zip(row.fields.indices, row.fields) {
			self[field.name] = row[index]
		}
	}
}
