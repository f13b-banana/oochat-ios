import Foundation
import XCTest
@testable import ConnectOnionKit

final class JSONValueTests: XCTestCase {
    func testString() throws {
        let json = Data(#"{"name":"Jane"}"#.utf8)

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: json
        )

        guard case .object(let object) = value else {
            XCTFail("Expected JSON object")
            return
        }

        XCTAssertEqual(object["name"]?.stringValue, "Jane")
    }

    func testNumber() throws {
        let json = Data(#"{"count":42}"#.utf8)

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: json
        )

        guard case .object(let object) = value else {
            XCTFail("Expected JSON object")
            return
        }

        XCTAssertEqual(object["count"]?.numberValue, 42)
    }

    func testBoolean() throws {
        let json = Data(#"{"enabled":true}"#.utf8)

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: json
        )

        guard case .object(let object) = value else {
            XCTFail("Expected JSON object")
            return
        }

        XCTAssertEqual(object["enabled"], JSONValue.bool(true))
    }

    func testNull() throws {
        let json = Data(#"{"value":null}"#.utf8)

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: json
        )

        guard case .object(let object) = value else {
            XCTFail("Expected JSON object")
            return
        }

        XCTAssertEqual(object["value"], JSONValue.null)
    }

    func testArray() throws {
        let json = Data(#"{"values":[1,2,3]}"#.utf8)

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: json
        )

        guard case .object(let object) = value else {
            XCTFail("Expected JSON object")
            return
        }

        XCTAssertEqual(
            object["values"],
            JSONValue.array([
                .number(1),
                .number(2),
                .number(3)
            ])
        )
    }

    func testJSONRoundTrip() throws {
        let original = Data("""
        {
            "name": "test",
            "count": 42,
            "enabled": true,
            "values": [1, 2, 3],
            "nested": {
                "hello": "world"
            },
            "nothing": null
        }
        """.utf8)

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: original
        )

        let encoded = try JSONEncoder().encode(value)

        let decodedAgain = try JSONDecoder().decode(
            JSONValue.self,
            from: encoded
        )

        XCTAssertEqual(value, decodedAgain)
    }

    /// JSONSerialisation goves NSNumber for 1, 0 and true alike, only CFBoolean is a bool
    func testOneAndZeroAreNumbers() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"one":1,"zero":0,"yes":true,"no":false}"#.utf8))

        XCTAssertEqual(JSONValue(any: parsed),
                       .object(["one": .number(1), "zero": .number(0), "yes": .bool(true), "no": .bool(false)])
        )
    }

    func testSwiftBoolsAndNumbers() {
        XCTAssertEqual(JSONValue(any: true), .bool(true))
        XCTAssertEqual(JSONValue(any: 1), .number(1))
        XCTAssertEqual(JSONValue(any: 2.5), .number(2.5))
    }
}
