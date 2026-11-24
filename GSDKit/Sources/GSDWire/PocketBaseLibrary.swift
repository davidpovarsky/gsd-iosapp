import Foundation
import GSDModel

extension PocketBaseClient {
    package func listLibrary(token: String) async throws -> [CloudLibraryItem] {
        struct Page: Decodable { var items: [CloudLibraryItem]; var totalPages: Int; var totalItems: Int }
        var result: [CloudLibraryItem] = []
        var seen = Set<String>()
        for page in 1...100 {
            let path = "/api/collections/gsd_library/records?perPage=100&page=\(page)&sort=id"
            let response = try await send(authedRequest(path: path, method: "GET", token: token), as: Page.self)
            for item in response.items {
                guard ["archive", "trash", "view"].contains(item.kind), seen.insert(item.key).inserted else {
                    throw RemoteListingIncomplete(reason: "Invalid or repeated library item")
                }
                result.append(item)
            }
            if page >= response.totalPages {
                guard result.count == response.totalItems else {
                    throw RemoteListingIncomplete(reason: "Incomplete library listing")
                }
                return result
            }
        }
        throw RemoteListingIncomplete(reason: "Library exceeds page limit")
    }

    package func putLibrary(_ item: CloudLibraryItem, expectedVersion: String, token: String) async throws {
        struct Body: Encodable {
            var expected_version: String
            var client_updated_at: String
            var payload: String
            var deleted: Bool
        }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard item.entityId.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            throw PocketBaseError.decoding("Invalid library id")
        }
        let version: String
        if item.clientUpdatedAt == expectedVersion, let previous = WireDate.parse(expectedVersion) {
            version = WireDate.format(previous.addingTimeInterval(0.001))
        } else {
            version = item.clientUpdatedAt
        }
        let body = Body(expected_version: expectedVersion, client_updated_at: version,
                        payload: item.payload, deleted: item.deleted)
        try await sendNoContent(authedRequest(
            path: "/api/gsd/library/\(item.kind)/\(item.entityId)", method: "PUT",
            token: token, body: try JSONEncoder().encode(body)))
    }
}
