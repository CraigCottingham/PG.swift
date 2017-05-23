import Foundation


extension UUID: PostgresRepresentable {
	public static var pgTypes: [OID] {
		return [.uuid]
	}
	
	public init?(pgText text: String) {
		self.init(uuidString: text)
	}
	
	public var pgText: String? {
		return self.uuidString
	}
}