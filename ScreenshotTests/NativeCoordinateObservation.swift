import XCTest

@MainActor
extension XCTestCase {
    /// Resolve a measured screen point through a real native element. Record the
    /// actual coordinate basis before requiring agreement; frame.origin alone is
    /// not evidence of the origin used by XCUICoordinate in every orientation.
    func measuredNativeCoordinate(on element: XCUIElement, at target: CGPoint,
                                  observationName: String) -> XCUICoordinate? {
        let frame = element.frame
        let anchor = element.coordinate(withNormalizedOffset: .zero)
        let origin = anchor.screenPoint
        let unitX = anchor.withOffset(CGVector(dx: 1, dy: 0)).screenPoint
        let unitY = anchor.withOffset(CGVector(dx: 0, dy: 1)).screenPoint
        let xx = unitX.x - origin.x
        let xy = unitX.y - origin.y
        let yx = unitY.x - origin.x
        let yy = unitY.y - origin.y
        let determinant = xx * yy - xy * yx
        var observation = "element=\(element.identifier) frame=\(frame) "
            + "origin=\(origin) unitX=\(unitX) unitY=\(unitY) "
            + "determinant=\(determinant) target=\(target)"
        func record() {
            let attachment = XCTAttachment(string: observation)
            attachment.name = observationName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        guard [origin.x, origin.y, unitX.x, unitX.y, unitY.x, unitY.y,
               target.x, target.y, determinant].allSatisfy({ $0.isFinite }),
              abs(determinant) > 0.000001 else {
            record()
            XCTFail("The observed native coordinate basis must be finite and invertible")
            return nil
        }
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let offset = CGVector(dx: (dx * yy - dy * yx) / determinant,
                              dy: (xx * dy - xy * dx) / determinant)
        let coordinate = anchor.withOffset(offset)
        let resolved = coordinate.screenPoint
        observation += " offset=\(offset) resolved=\(resolved)"
        record()
        guard resolved.x.isFinite && resolved.y.isFinite
                && abs(resolved.x - target.x) < 1
                && abs(resolved.y - target.y) < 1 else {
            XCTFail("Native coordinate disagrees with the measured screen target")
            return nil
        }
        return coordinate
    }
}
