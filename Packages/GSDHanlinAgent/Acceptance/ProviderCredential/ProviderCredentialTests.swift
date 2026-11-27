import Foundation
import XCTest
@testable import ProviderCredentialFixture

@MainActor
final class ProviderCredentialTests: XCTestCase {
    func testDifferentCredentialsAtSameEndpointHaveDifferentConversationScopes() throws {
        let bytes = FixtureBytes()
        let store = bytes.store
        let first = try XCTUnwrap(store.save("fixture-key-a"))
        let second = try XCTUnwrap(store.save("fixture-key-b"))
        XCTAssertNotEqual(first.registrationID, second.registrationID)
        XCTAssertNotEqual(first.conversationAccountID(endpoint: "https://provider.invalid/v1"),
                          second.conversationAccountID(endpoint: "https://provider.invalid/v1"))
        XCTAssertFalse(second.conversationAccountID(endpoint: "https://provider.invalid/v1").contains("fixture-key"))
    }

    func testUnchangedCredentialPreservesRegistrationAcrossReadAndModelSettingsSave() throws {
        let bytes = FixtureBytes()
        let original = try XCTUnwrap(bytes.store.save("fixture-key"))
        let reopened = try XCTUnwrap(bytes.store.read())
        let savedAgain = try XCTUnwrap(bytes.store.save("fixture-key"))
        XCTAssertEqual(original, reopened)
        XCTAssertEqual(original, savedAgain, "Model-only settings saves must not reset the conversation")
        XCTAssertNotEqual(original.conversationAccountID(endpoint: "https://provider-a.invalid/v1"),
                          original.conversationAccountID(endpoint: "https://provider-b.invalid/v1"))
    }

    func testLegacyCredentialMigratesOnceAndKeepsItsRegistration() throws {
        let bytes = FixtureBytes()
        bytes.data = Data("fixture-legacy-key".utf8)
        let first = try XCTUnwrap(bytes.store.read())
        XCTAssertEqual(first.credential, "fixture-legacy-key")
        XCTAssertEqual(bytes.writes, 1)
        let reopened = try XCTUnwrap(bytes.store.read())
        XCTAssertEqual(reopened, first)
        XCTAssertEqual(bytes.writes, 1, "Reopening must not generate another account identity")
    }

    func testFailedMigrationPreservesLegacyBytesAndDoesNotPublishAnIdentity() throws {
        let bytes = FixtureBytes()
        let legacy = Data("fixture-legacy-key".utf8)
        bytes.data = legacy
        bytes.refuseWrites = true
        XCTAssertThrowsError(try bytes.store.read())
        XCTAssertEqual(bytes.data, legacy)
        bytes.refuseWrites = false
        let recovered = try XCTUnwrap(bytes.store.read())
        XCTAssertEqual(recovered.credential, "fixture-legacy-key")
        XCTAssertEqual(try bytes.store.read(), recovered)
    }

    func testFailedReplacementPreservesPreviousCredentialAndRegistrationTogether() throws {
        let bytes = FixtureBytes()
        let original = try XCTUnwrap(bytes.store.save("fixture-key-a"))
        let before = bytes.data
        bytes.refuseWrites = true
        XCTAssertThrowsError(try bytes.store.save("fixture-key-b"))
        XCTAssertEqual(bytes.data, before)
        XCTAssertEqual(try bytes.store.read(), original)
    }

    func testClearThenReenterCreatesAnotherRegistration() throws {
        let bytes = FixtureBytes()
        let original = try XCTUnwrap(bytes.store.save("fixture-key"))
        XCTAssertNil(try bytes.store.save(""))
        XCTAssertNil(try bytes.store.read())
        let replacement = try XCTUnwrap(bytes.store.save("fixture-key"))
        XCTAssertNotEqual(replacement.registrationID, original.registrationID)
    }
}

@MainActor
private final class FixtureBytes {
    var data: Data?
    var refuseWrites = false
    var writes = 0

    var store: GSDHanlinProviderCredentialStore {
        .init(loadData: { self.data }, saveData: { value in
            if self.refuseWrites { throw NSError(domain: "FixtureKeychain", code: -1) }
            self.data = value
            self.writes += 1
        }, deleteData: { self.data = nil })
    }
}
