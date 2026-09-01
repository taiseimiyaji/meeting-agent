import Foundation
import XCTest
@testable import LocalAPI

final class HTTPParserTests: XCTestCase {
    func testParsesBodyOnlyWhenComplete() throws {
        let incomplete = Data("POST /api/capture/start HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Length: 2\r\n\r\n{".utf8)
        XCTAssertNil(HTTPParser.parse(incomplete)); var complete = incomplete; complete.append(contentsOf: Data("}".utf8))
        let request = try XCTUnwrap(HTTPParser.parse(complete)); XCTAssertEqual(request.method, .POST); XCTAssertEqual(request.body, Data("{}".utf8))
    }
    func testRejectsOversizedBodyBeforeReadingIt() {
        XCTAssertNil(HTTPParser.parse(Data("POST /api/capture/start HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Length: 1048577\r\n\r\n".utf8)))
    }
}
