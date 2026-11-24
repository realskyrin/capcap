import AppKit
import XCTest
@testable import capcap

final class ToolbarLayoutTests: XCTestCase {
    func testDefaultPlacesCropBeforeRotate() throws {
        let primary = ToolbarLayout.default.primary
        let cropIndex = try XCTUnwrap(primary.firstIndex(of: .crop))
        XCTAssertEqual(primary[cropIndex + 1], .rotate)
        XCTAssertNil(ToolbarItemID.crop.editTool)
        XCTAssertEqual(ToolbarItemID.crop.kind, .toggleAction)
        XCTAssertNotNil(ToolbarItemID.crop.iconImage(pointSize: 16))
    }

    func testOlderPersistedLayoutAddsCropBesideRotateInItsExistingBucket() {
        for bucket in ["primary", "side", "hidden"] {
            var dictionary = ToolbarLayout.default.dictionary
            for key in ["primary", "side", "hidden"] {
                dictionary[key]?.removeAll { $0 == "crop" || $0 == "rotate" }
            }
            dictionary[bucket, default: []].append("rotate")
            let normalized = ToolbarLayout(dictionary: dictionary).normalized().dictionary

            for key in ["primary", "side", "hidden"] {
                let expected = dictionary[key]?.flatMap { $0 == "rotate" ? ["crop", "rotate"] : [$0] }
                XCTAssertEqual(normalized[key], expected)
            }
        }
    }

    func testOlderLayoutWithoutRotateAddsCropBeforeNewRotate() throws {
        var oldLayout = ToolbarLayout.default
        oldLayout.primary.removeAll { $0 == .crop || $0 == .rotate }
        let normalized = oldLayout.normalized()
        let cropIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .crop))
        XCTAssertEqual(normalized.primary[cropIndex + 1], .rotate)
        XCTAssertEqual(normalized.primary[cropIndex + 2], .beautify)
    }

    func testExplicitlyHiddenCropRemainsHidden() {
        var layout = ToolbarLayout.default
        layout.primary.removeAll { $0 == .crop }
        layout.hidden.append(.crop)
        XCTAssertEqual(layout.normalized(), layout)
    }

    func testDefaultPlacesSpotlightBetweenMarkerAndMosaic() throws {
        let primary = ToolbarLayout.default.primary
        let markerIndex = try XCTUnwrap(primary.firstIndex(of: .marker))
        let spotlightIndex = try XCTUnwrap(primary.firstIndex(of: .spotlight))
        let mosaicIndex = try XCTUnwrap(primary.firstIndex(of: .mosaic))

        XCTAssertEqual(spotlightIndex, markerIndex + 1)
        XCTAssertEqual(mosaicIndex, spotlightIndex + 1)
    }

    func testOlderPersistedLayoutAddsSpotlightAfterMarker() throws {
        let oldLayout = ToolbarLayout(
            primary: [.rectangle, .marker, .mosaic],
            side: [.save, .confirm],
            hidden: ToolbarLayout.canonicalOrder.filter {
                ![.rectangle, .marker, .spotlight, .mosaic, .save, .confirm].contains($0)
            }
        )

        let normalized = oldLayout.normalized()
        let markerIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .marker))
        let spotlightIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .spotlight))
        let mosaicIndex = try XCTUnwrap(normalized.primary.firstIndex(of: .mosaic))

        XCTAssertEqual(spotlightIndex, markerIndex + 1)
        XCTAssertEqual(mosaicIndex, spotlightIndex + 1)
    }

    func testSpotlightToolbarSymbolExistsOnSupportedmacOS() {
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: ToolbarItemID.spotlight.symbolName,
                accessibilityDescription: nil
            )
        )
    }
}
