import Flutter
import UIKit
import XCTest

// If your plugin has been explicitly set to "type: .dynamic" in the Package.swift,
// you will need to add your plugin as a dependency of RunnerTests within Xcode.

@testable import keychain

class RunnerTests: XCTestCase {

  func testMalformedKeyIdIsRefusedBeforeTheKeychain() {
    let plugin = KeychainPlugin()

    let call = FlutterMethodCall(methodName: "exists", arguments: ["keyId": "not-an-id"])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual((result as? FlutterError)?.code, "badArgs")
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

}
