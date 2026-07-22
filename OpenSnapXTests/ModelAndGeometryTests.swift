import CoreGraphics
import XCTest
@testable import OpenSnapX

final class ModelAndGeometryTests: XCTestCase {
    func testAnnotationStyleDefaultsToFifteenPointStroke() {
        XCTAssertEqual(AnnotationStyle().lineWidth, 15)
    }

    func testDisplayPointSizeExpandsToRetinaCapturePixels() {
        let pixels = DisplayGeometry.pixelSize(from: CGSize(width: 1512, height: 982), scale: 2)
        XCTAssertEqual(pixels, CGSize(width: 3024, height: 1964))
    }

    func testDisplayPointSizeStaysUnchangedAtOneX() {
        let pixels = DisplayGeometry.pixelSize(from: CGSize(width: 1920, height: 1080), scale: 1)
        XCTAssertEqual(pixels, CGSize(width: 1920, height: 1080))
    }

    func testPixelConversionForRetinaDisplayWithNegativeOrigin() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: -1340, y: 650, width: 200, height: 100)
        let pixels = DisplayGeometry.pixelRect(from: selection, screenFrame: screen, scale: 2)
        XCTAssertEqual(pixels, CGRect(x: 200, y: 300, width: 400, height: 200))
    }

    func testPixelConversionForVerticallyArrangedDisplay() {
        let screen = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let selection = CGRect(x: 10, y: 1870, width: 100, height: 50)
        let pixels = DisplayGeometry.pixelRect(from: selection, screenFrame: screen, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 10, y: 60, width: 100, height: 50))
    }

    func testRegionLayoutSpansSideBySideDisplays() throws {
        let screens = [
            DisplayGeometry.ScreenDescriptor(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                scale: 1
            ),
            DisplayGeometry.ScreenDescriptor(
                displayID: 2,
                frame: CGRect(x: 1000, y: 0, width: 1200, height: 900),
                scale: 1
            )
        ]

        let layout = try XCTUnwrap(DisplayGeometry.regionLayout(
            for: CGRect(x: 900, y: 200, width: 300, height: 200),
            screens: screens
        ))

        XCTAssertEqual(layout.pixelSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(layout.slices.map(\.displayID), [1, 2])
        XCTAssertEqual(layout.slices[0].sourcePixelRect, CGRect(x: 900, y: 400, width: 100, height: 200))
        XCTAssertEqual(layout.slices[0].destinationPixelRect, CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(layout.slices[1].sourcePixelRect, CGRect(x: 0, y: 500, width: 200, height: 200))
        XCTAssertEqual(layout.slices[1].destinationPixelRect, CGRect(x: 100, y: 0, width: 200, height: 200))
    }

    func testRegionLayoutUsesHighestScaleAcrossDisplays() throws {
        let screens = [
            DisplayGeometry.ScreenDescriptor(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                scale: 2
            ),
            DisplayGeometry.ScreenDescriptor(
                displayID: 2,
                frame: CGRect(x: 1000, y: 200, width: 1200, height: 900),
                scale: 1
            )
        ]

        let layout = try XCTUnwrap(DisplayGeometry.regionLayout(
            for: CGRect(x: 900, y: 600, width: 300, height: 100),
            screens: screens
        ))

        XCTAssertEqual(layout.scale, 2)
        XCTAssertEqual(layout.pixelSize, CGSize(width: 600, height: 200))
        XCTAssertEqual(layout.slices[0].sourcePixelRect, CGRect(x: 1800, y: 200, width: 200, height: 200))
        XCTAssertEqual(layout.slices[0].destinationPixelRect, CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(layout.slices[1].sourcePixelRect, CGRect(x: 0, y: 400, width: 200, height: 100))
        XCTAssertEqual(layout.slices[1].destinationPixelRect, CGRect(x: 200, y: 0, width: 400, height: 200))
    }

    func testOverlayHintGeometryRejectsSelectionOutsideCurrentDisplay() {
        let visibleSelection = CaptureOverlayGeometry.visibleSelection(
            CGRect(x: 1200, y: 100, width: 200, height: 100),
            within: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertNil(visibleSelection)
        XCTAssertFalse(CaptureOverlayGeometry.isValidHintPoint(
            CGPoint(x: CGFloat.nan, y: 100)
        ))
    }

    func testOverlayHintGeometryAcceptsFiniteDisplayIntersection() throws {
        let visibleSelection = try XCTUnwrap(CaptureOverlayGeometry.visibleSelection(
            CGRect(x: 900, y: 100, width: 200, height: 100),
            within: CGRect(x: 0, y: 0, width: 1000, height: 800)
        ))

        XCTAssertEqual(visibleSelection, CGRect(x: 900, y: 100, width: 100, height: 100))
        XCTAssertTrue(CaptureOverlayGeometry.isValidHintPoint(
            CGPoint(x: visibleSelection.midX, y: visibleSelection.midY)
        ))
    }

    func testOverlayPanelUsesScreenLocalContentRectForOffsetDisplay() {
        let screenFrame = CGRect(x: -470, y: 982, width: 2560, height: 1440)

        XCTAssertEqual(
            CaptureOverlayGeometry.panelContentRect(for: screenFrame),
            CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
    }

    func testQuartzWindowFrameUsesPrimaryDisplayTopForVerticalLayouts() {
        let quartzFrame = CGRect(x: 100, y: -700, width: 800, height: 600)
        let appKitFrame = DisplayGeometry.appKitRect(
            fromQuartzRect: quartzFrame,
            primaryDisplayTop: 1080
        )
        XCTAssertEqual(appKitFrame, CGRect(x: 100, y: 1180, width: 800, height: 600))
    }

    func testWindowSelectionUsesFrontToBackWindowOrder() {
        let back = windowCandidate(id: 10, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let front = windowCandidate(id: 20, frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let ordered = WindowSelectionEngine.orderedFrontToBack([back, front], windowIDs: [20, 10])

        XCTAssertEqual(
            WindowSelectionEngine.frontmostCandidate(at: CGPoint(x: 150, y: 150), in: ordered)?.id,
            front.id
        )
        XCTAssertEqual(
            WindowSelectionEngine.frontmostCandidate(at: CGPoint(x: 50, y: 50), in: ordered)?.id,
            back.id
        )
    }

    func testWindowSelectionIgnoresDockSizedSystemWindow() {
        let dock = windowCandidate(
            id: 30,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            bundleIdentifier: "com.apple.dock",
            windowLayer: 20
        )
        let appWindow = windowCandidate(
            id: 40,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        XCTAssertEqual(
            WindowSelectionEngine.frontmostCandidate(
                at: CGPoint(x: 300, y: 300),
                in: [dock, appWindow]
            )?.id,
            appWindow.id
        )
        XCTAssertNil(WindowSelectionEngine.frontmostCandidate(
            at: CGPoint(x: 10, y: 10),
            in: [dock]
        ))
    }

    func testWindowSelectionAllowsFloatingApplicationWindow() {
        let floatingPanel = windowCandidate(
            id: 50,
            frame: CGRect(x: 100, y: 100, width: 400, height: 300),
            windowLayer: 3
        )
        let appWindow = windowCandidate(
            id: 60,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(
            WindowSelectionEngine.frontmostCandidate(
                at: CGPoint(x: 200, y: 200),
                in: [floatingPanel, appWindow]
            )?.id,
            floatingPanel.id
        )
    }

    func testMovingAnnotationPointsMovesRenderedLineWithItsFrame() {
        let points = [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))]
        let moved = AnnotationCanvasGeometry.movedPoints(points, by: CGPoint(x: 15, y: -5))
        XCTAssertEqual(moved.map(\.cgPoint), [CGPoint(x: 25, y: 15), CGPoint(x: 105, y: 55)])
    }

    func testTranslatingAnnotationMovesFrameAndPointsTogether() {
        let annotation = Annotation(
            kind: .pen,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))]
        )
        let translated = AnnotationCanvasGeometry.translated(annotation, by: CGPoint(x: 12, y: 12))
        XCTAssertEqual(translated.frame.cgRect, CGRect(x: 22, y: 32, width: 80, height: 40))
        XCTAssertEqual(translated.points.map(\.cgPoint), [CGPoint(x: 22, y: 32), CGPoint(x: 102, y: 72)])
    }

    func testResizingAnnotationPointsMovesLineEndpoints() {
        let points = [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))]
        let resized = AnnotationCanvasGeometry.resizedPoints(
            points,
            from: CGRect(x: 10, y: 20, width: 80, height: 40),
            to: CGRect(x: 10, y: 20, width: 160, height: 80)
        )
        XCTAssertEqual(resized.map(\.cgPoint), [CGPoint(x: 10, y: 20), CGPoint(x: 170, y: 100)])
    }

    func testFreehandGeometryFrameContainsEveryPointInsteadOfOnlyEndpoints() {
        let annotation = Annotation(
            kind: .pen,
            frame: CanvasRect(CGRect(x: 100, y: 100, width: 20, height: 20)),
            points: [
                CanvasPoint(CGPoint(x: 100, y: 100)),
                CanvasPoint(CGPoint(x: 25, y: 180)),
                CanvasPoint(CGPoint(x: 160, y: 240)),
                CanvasPoint(CGPoint(x: 120, y: 120))
            ]
        )

        XCTAssertEqual(
            AnnotationCanvasGeometry.geometryFrame(for: annotation),
            CGRect(x: 25, y: 100, width: 135, height: 140)
        )
    }

    func testNonFreehandGeometryKeepsStoredFrame() {
        let annotation = Annotation(
            kind: .rectangle,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 0, y: 0))]
        )

        XCTAssertEqual(
            AnnotationCanvasGeometry.geometryFrame(for: annotation),
            annotation.frame.cgRect
        )
    }

    func testCounterFontScalesWithShortestDimensionWhenResized() {
        XCTAssertEqual(
            AnnotationCanvasGeometry.resizedFontSize(
                24,
                from: CGRect(x: 0, y: 0, width: 64, height: 32),
                to: CGRect(x: 0, y: 0, width: 64, height: 64)
            ),
            48
        )
    }

    func testCounterFontDoesNotScaleWhenOnlyLongDimensionChanges() {
        XCTAssertEqual(
            AnnotationCanvasGeometry.resizedFontSize(
                24,
                from: CGRect(x: 0, y: 0, width: 32, height: 32),
                to: CGRect(x: 0, y: 0, width: 64, height: 32)
            ),
            24
        )
    }

    func testSelectionGeometryIncludesStrokeAndOverlayPadding() {
        let annotation = Annotation(
            kind: .pen,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))],
            style: AnnotationStyle(lineWidth: 10)
        )

        XCTAssertEqual(
            AnnotationCanvasGeometry.selectionFrame(for: annotation, overlayPadding: 5),
            CGRect(x: 0, y: 10, width: 100, height: 60)
        )
    }

    func testResizeGeometryMovesOnlyRequestedEdges() {
        let resized = AnnotationCanvasGeometry.resizedFrame(
            CGRect(x: 10, y: 20, width: 80, height: 40),
            for: .resizeTopLeft,
            by: CGPoint(x: 15, y: 10)
        )

        XCTAssertEqual(resized, CGRect(x: 25, y: 30, width: 65, height: 30))
    }

    func testCornerHandleTakesPriorityOverAnnotationBody() {
        let annotation = Annotation(
            kind: .rectangle,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40))
        )

        XCTAssertEqual(
            AnnotationCanvasGeometry.dragOperation(
                for: annotation,
                at: CGPoint(x: 5, y: 15),
                selectionPadding: 5,
                handleSize: 20
            ),
            .resizeTopLeft
        )
    }

    func testLineHitAreaIsEasierThanItsVisibleStroke() {
        let distance = AnnotationCanvasGeometry.distance(
            from: CGPoint(x: 50, y: 26),
            toSegmentFrom: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 90, y: 20)
        )
        XCTAssertEqual(distance, 6, accuracy: 0.001)
    }

    func testImageResizeScalesEditableAnnotationGeometryAndStyles() {
        let textStyle = RichTextStyle(fontSize: 20)
        let annotation = Annotation(
            kind: .text,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))],
            text: "Resize",
            richText: RichTextDocument(
                string: "Resize",
                runs: [RichTextRun(location: 0, length: 6, style: textStyle)]
            ),
            style: AnnotationStyle(lineWidth: 8, fontSize: 20)
        )

        let resized = ImageResizeGeometry.scaledAnnotations(
            [annotation],
            from: CGSize(width: 100, height: 100),
            to: CGSize(width: 50, height: 50)
        )[0]

        XCTAssertEqual(resized.frame.cgRect, CGRect(x: 5, y: 10, width: 40, height: 20))
        XCTAssertEqual(resized.points.map(\.cgPoint), [CGPoint(x: 5, y: 10), CGPoint(x: 45, y: 30)])
        XCTAssertEqual(resized.style.lineWidth, 4, accuracy: 0.001)
        XCTAssertEqual(resized.style.fontSize, 10, accuracy: 0.001)
        XCTAssertEqual(resized.richText?.runs[0].style.fontSize, 10)
    }

    func testCaptureResultBuildsImmediateInMemorySession() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceRect = CanvasRect(CGRect(x: 10, y: 20, width: 320, height: 180))
        let result = CaptureResult(
            image: try solidImage(width: 320, height: 180),
            mode: .region,
            createdAt: createdAt,
            displayScale: 2,
            sourceRect: sourceRect
        )
        let session = CaptureSession(captureResult: result)

        XCTAssertEqual(session.id, result.id)
        XCTAssertEqual(session.manifest.createdAt, createdAt)
        XCTAssertEqual(session.manifest.modifiedAt, createdAt)
        XCTAssertEqual(session.manifest.pixelWidth, 320)
        XCTAssertEqual(session.manifest.pixelHeight, 180)
        XCTAssertEqual(session.manifest.displayScale, 2)
        XCTAssertEqual(session.manifest.sourceRect, sourceRect)
        XCTAssertEqual(session.manifest.outputPixelSize, CGSize(width: 320, height: 180))
        XCTAssertNil(session.manifest.resize)
        XCTAssertTrue(session.annotations.isEmpty)
        XCTAssertTrue(session.ocrResults.isEmpty)
    }

    func testRichTextAnnotationRoundTripsAllFormatting() throws {
        let firstStyle = RichTextStyle(
            fontFamily: "Helvetica",
            fontSize: 28,
            isBold: true,
            isItalic: true,
            isUnderlined: true,
            isStruckThrough: true,
            foregroundColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1),
            backgroundColor: RGBAColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.6),
            alignment: .center
        )
        let secondStyle = RichTextStyle(
            fontFamily: "Menlo",
            fontSize: 18,
            foregroundColor: .black,
            alignment: .right
        )
        let document = RichTextDocument(
            string: "Styled text",
            runs: [
                RichTextRun(location: 0, length: 6, style: firstStyle),
                RichTextRun(location: 6, length: 5, style: secondStyle)
            ]
        )
        let annotation = Annotation(
            kind: .text,
            frame: CanvasRect(CGRect(x: 20, y: 30, width: 240, height: 80)),
            text: document.string,
            richText: document
        )

        let data = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)

        XCTAssertEqual(decoded, annotation)
        XCTAssertEqual(decoded.richText, document)
    }

    func testCaptureSessionRoundTripsVersionedAnnotations() throws {
        let annotation = Annotation(
            kind: .arrow,
            frame: CanvasRect(CGRect(x: 10, y: 20, width: 80, height: 40)),
            points: [CanvasPoint(CGPoint(x: 10, y: 20)), CanvasPoint(CGPoint(x: 90, y: 60))],
            style: AnnotationStyle(strokeColor: .red, lineWidth: 7)
        )
        let manifest = CaptureManifest(
            id: UUID(), createdAt: .now, modifiedAt: .now, captureMode: .region,
            pixelWidth: 800, pixelHeight: 600, displayScale: 2
        )
        var resizedManifest = manifest
        resizedManifest.resize = ImageResizeConfiguration(pixelWidth: 400, pixelHeight: 300)
        let session = CaptureSession(manifest: resizedManifest, annotations: [annotation], ocrResults: [])
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)
        XCTAssertEqual(decoded.manifest.schemaVersion, 1)
        XCTAssertEqual(decoded.manifest.outputPixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(decoded.annotations, [annotation])
    }

    private func windowCandidate(
        id: UInt32,
        frame: CGRect,
        bundleIdentifier: String = "example.test",
        windowLayer: Int = 0
    ) -> WindowCandidate {
        WindowCandidate(
            id: id,
            title: "Window \(id)",
            applicationName: "Test App",
            bundleIdentifier: bundleIdentifier,
            processID: 1,
            frame: frame,
            isOnScreen: true,
            windowLayer: windowLayer
        )
    }

    func testManifestWithoutResizeConfigurationRemainsDecodable() throws {
        let manifest = CaptureManifest(
            id: UUID(), createdAt: .now, modifiedAt: .now, captureMode: .region,
            pixelWidth: 800, pixelHeight: 600, displayScale: 2
        )
        let encoded = try JSONEncoder().encode(manifest)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "resize")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: legacyData)

        XCTAssertNil(decoded.resize)
        XCTAssertEqual(decoded.outputPixelSize, CGSize(width: 800, height: 600))
    }
}
