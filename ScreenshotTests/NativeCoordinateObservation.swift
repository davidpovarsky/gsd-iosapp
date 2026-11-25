import XCTest

@MainActor
extension XCTestCase {
    /// Resolve a point measured in the element.frame display coordinate system.
    /// In landscape, XCUICoordinate.screenPoint uses the rotated native/HID
    /// coordinate system. Keep those domains distinct and record their mapping.
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
        var observation = "element=\(element.identifier) displayFrame=\(frame) "
            + "nativeOrigin=\(origin) nativeUnitX=\(unitX) nativeUnitY=\(unitY) "
            + "determinant=\(determinant) displayTarget=\(target)"
        func record() {
            let attachment = XCTAttachment(string: observation)
            attachment.name = observationName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        guard [origin.x, origin.y, unitX.x, unitX.y, unitY.x, unitY.y,
               frame.minX, frame.minY, target.x, target.y, determinant]
                .allSatisfy({ $0.isFinite }),
              abs(determinant) > 0.000001 else {
            record()
            XCTFail("The observed native coordinate basis must be finite and invertible")
            return nil
        }
        let offset = CGVector(dx: target.x - frame.minX, dy: target.y - frame.minY)
        let expectedNative = CGPoint(x: origin.x + xx * offset.dx + yx * offset.dy,
                                     y: origin.y + xy * offset.dx + yy * offset.dy)
        let coordinate = anchor.withOffset(offset)
        let resolved = coordinate.screenPoint
        observation += " displayOffset=\(offset) expectedNative=\(expectedNative) "
            + "resolvedNative=\(resolved)"
        record()
        guard expectedNative.x.isFinite && expectedNative.y.isFinite
                && resolved.x.isFinite && resolved.y.isFinite
                && abs(resolved.x - expectedNative.x) < 1
                && abs(resolved.y - expectedNative.y) < 1 else {
            XCTFail("Native coordinate disagrees with the measured display-to-native mapping")
            return nil
        }
        return coordinate
    }
}
