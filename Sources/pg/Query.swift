import Foundation


/// An SQL query
public struct Query {
	/// A query specific error
	///
	/// - wrongNumberOfBindings: When updating the bindings of a query, if it has a prepared statement the number of bindings must match the number of prepared bindings.
	/// - mismatchedBindingType: When updating the bindings of a query, if it has a prepared statement the types of the bindings must match.
	public enum Error: Swift.Error {
		case wrongNumberOfBindings
		case mismatchedBindingType(value: Any?, index: Int, expectedType: Any.Type?)
	}
	
	
	/// A prepared statement for reuse of a query
	public final class Statement: Equatable {
		/// The name of the statement used on the server
		public let name: String
		
		/// The text of the SQL query
		///
		/// This could either represent the entire query (if bindings are empty) or the statement part of the query with `$x` placeholders for the bindings.
		public let string: String
		
		/// The types to use for the statement, or nil to not specify a type
		public let bindingTypes: [PostgresCodable.Type?]
		
		fileprivate init(name: String = UUID().uuidString, string: String, bindingTypes: [PostgresCodable.Type?]) {
			self.name = name
			self.string = string
			self.bindingTypes = bindingTypes
		}
		
		/// Statements are ony equal to themselves, even if 2 different statements have the same name and types.
		public static func == (_ lhs: Statement, _ rhs: Statement) -> Bool {
			return lhs === rhs
		}
	}
	
	/// Indicates if the more complicated extended excecution workflow needs to be used
	///
	/// While any query can use the extended excecution workflow, using the simple query interface is faster because only a single message needs to be sent to the server. However, if the query has bindings or a previously prepared statement it must use the extended workflow.
	public var needsExtendedExcecution: Bool {
		if self.bindings.count > 0 || self.statement != nil {
			return true
		} else {
			return false
		}
	}
	
	/// The statement to use between excecutions of a query
	///
	/// If this is not nil the statement will be reused between calls. If it is nil, a new statement will be generated each time.
	private(set) public var statement: Statement?
	
	/// The types of the bindings values
	///
	/// Due to a limitation in the current version of swift, we cannot get the types of nil values.
	public var currentBindingTypes: [PostgresCodable.Type?] {
		return self.bindings.map({ value in
			if let value = value {
				return type(of: value)
			} else {
				// unfortunately swift doesn't keep track of nil types
				// maybe in swift 4 we can conform Optional to PostgresCodable when it's wrapped type is?
				return nil
			}
		})
	}
	
	/// Create and return a new prepared statement for the receiver
	///
	/// Normally a query is prepared and excecuted at the same time. However, if you have a query that gets reused often, even if it's bindings change between calls, you can optimize performance by reusing the same query and statement.
	///
	/// This method generates a statement locally, but does not prepare it with the server. Creating a statement indicates to the Client that the query should be reused. If a query has a statement set, calling `Client.exec` will automatically prepare the statement, and subsequent calls to exec on the same connection will reuse the statement. You can also explicitly prepare it using `Client.prepare`.
	///
	/// - Note: that once a query has a statement set, it's binding types are locked in and an error will be thrown if you try to update them with different types.
	///
	/// - Parameter name: The name to be used for the statement on the server. Names must be uique accross connections and it is recommended that you use the default, which will generate a UUID.
	/// - Parameter types: The types to use for the prepared statement. Defaulst to `currentBindingTypes`.
	/// - Returns: The statement that was created. This is also set on the receiver.
	public mutating func createStatement(withName name: String = UUID().uuidString, types: [PostgresCodable.Type?]? = nil) -> Statement {
		let statement = Statement(name: name, string: string, bindingTypes: types ?? self.currentBindingTypes)
		self.statement = statement
		
		return statement
	}
	
	
	/// The text of the SQL query
	///
	/// This could either represent the entire query (if bindings are empty) or the statement part of the query with `$x` placeholders for the bindings.
	public let string: String
	
	/// The values to bind the query to
	///
	/// It is highly recommended that any dynamic or user generated values be used as bindings and not embeded in the query string. Bindings are processed on the server and escaped to avoid SQL injection.
	public private(set) var bindings: [PostgresCodable?]
	
	/// Emitted when the query is excecuted, either successfully or with an error
	public let completed = EventEmitter<Result<QueryResult>>()
	
	
	/// Update the bindings with new values
	///
	/// If you are reusing a query, you can change the bindings between executions. However the types must match the types in `statement` or an error will be thrown.
	///
	/// If there is no prepared statement for the receiver, this just sets the values in bindings.
	///
	/// - Parameter bindings: The new values to bind to.
	/// - Throws: Query.Error if there is a prepared statement and it's types do not match.
	public mutating func update(bindings: [PostgresCodable?]) throws {
		if let statement = statement {
			guard bindings.count == statement.bindingTypes.count else { throw Error.wrongNumberOfBindings }
			
			// swift 4 should support 3 way zip
			for (index, (binding, bindingType)) in zip(bindings.indices, zip(bindings, statement.bindingTypes)) {
				if let binding = binding, type(of: binding) != bindingType {
					throw Error.mismatchedBindingType(value: binding, index: index, expectedType: bindingType)
				}
			}
		}
		
		self.bindings = bindings
	}
	
	
	/// Create a new query
	///
	/// - Parameters:
	///   - string: The query string. Note that string interpolation should be strongly avoided. Use bindings instead.
	///   - bindings: Any value bindings for the query string. Index 0 matches `$1` in the query string.
	public init(_ string: String, bindings: [PostgresCodable?]) {
		self.string = string
		self.bindings = bindings
	}
	
	/// Create a new query
	///
	/// - Parameters:
	///   - string: The query string. Note that string interpolation should be strongly avoided. Use bindings instead.
	///   - bindings: Any value bindings for the query string. Index 0 matches `$1` in the query string.
	public init(_ string: String, _ bindings: PostgresCodable?...) {
		self.init(string, bindings: bindings)
	}
}

extension Query: ExpressibleByStringLiteral {
	public init(stringLiteral value: String) {
		self.init(value)
	}
	
	public init(unicodeScalarLiteral value: String) {
		self.init(value)
	}
	
	public init(extendedGraphemeClusterLiteral value: String) {
		self.init(value)
	}
}
