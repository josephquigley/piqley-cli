import Foundation
import PiqleyCore

extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(value): value.map(\.foundationValue)
        case let .object(value): value.mapValues(\.foundationValue)
        }
    }
}
