import MapKit
import SwiftUI
import UIKit

/// Full-screen map: long-press to choose a destination, see route options before
/// starting, and follow the ride.
struct MapTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let provider = model.provider {
            ZStack(alignment: .bottom) {
                ProviderMapHost(view: provider.mapHostView)
                    .ignoresSafeArea(edges: .top)
                    .accessibilityLabel("Map. \(hint).")
                    .onAppear { provider.setMapVisible(true) }
                    .onDisappear { provider.setMapVisible(false) }

                HStack(spacing: 12) {
                    Label(hint, systemImage: hintSymbol)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                    Button {
                        provider.recenter()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Re-centre map")
                }
                .padding()
            }
        } else {
            ContentUnavailableView("Map unavailable", systemImage: "map",
                                   description: Text("This build has no live map provider."))
        }
    }

    private var hint: String {
        switch model.stage {
        case .choosing, .confirming, .failed: "Long-press to set a destination"
        case .requesting: "Finding routes…"
        case .preview: "Tap a route to select it"
        case .navigating: model.mode == .simulation ? "Simulated ride - not drawn on the map" : "Navigating"
        case .atStop: "At your stop"
        }
    }

    private var hintSymbol: String {
        if case .navigating = model.stage { return "location.north.line.fill" }
        return "hand.tap"
    }
}

@MainActor
final class RoutePreviewLayoutObserver: UIView {
    var onSizeChange: (() -> Void)?
    private var previousSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize else { return }
        previousSize = bounds.size
        onSizeChange?()
    }
}

@MainActor
final class RoutePreviewAnnotation: NSObject, @preconcurrency MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let overlay: MKPolyline
    let handle: PreparedRouteHandle
    let option: RouteOption
    let selected: Bool

    init(coordinate: CLLocationCoordinate2D, overlay: MKPolyline, handle: PreparedRouteHandle,
         option: RouteOption, selected: Bool) {
        self.coordinate = coordinate
        self.overlay = overlay
        self.handle = handle
        self.option = option
        self.selected = selected
    }
}

@MainActor
final class RoutePreviewAnnotationView: MKAnnotationView {
    var onSelect: (() -> Void)?
    private let button = UIButton(type: .system)
    private let pointer = CAShapeLayer()

    static let pointerHeight: CGFloat = 8
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 8
    private static let minimumWidth: CGFloat = 88
    private static let minimumHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 10

    static func text(for option: RouteOption) -> String {
        "\(Format.duration(option.expectedSeconds)) · \(Format.distance(option.distanceMetres))"
    }

    static func size(for option: RouteOption) -> CGSize {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let textSize = (text(for: option) as NSString).size(withAttributes: [.font: font])
        return CGSize(width: max(minimumWidth, ceil(textSize.width) + horizontalInset * 2),
                      height: max(minimumHeight, ceil(font.lineHeight) + verticalInset * 2) + pointerHeight)
    }

    init(annotation: RoutePreviewAnnotation) {
        super.init(annotation: annotation, reuseIdentifier: nil)
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
        isAccessibilityElement = false
        layer.addSublayer(pointer)
        addSubview(button)
        button.addTarget(self, action: #selector(selectRoute), for: .touchUpInside)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) {
            (view: RoutePreviewAnnotationView, _) in
            if let route = view.annotation as? RoutePreviewAnnotation { view.configure(route) }
        }
        configure(annotation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(_ route: RoutePreviewAnnotation) {
        let size = Self.size(for: route.option)
        frame = CGRect(origin: .zero, size: size)
        centerOffset = CGPoint(x: 0, y: -size.height / 2)
        let background: UIColor = route.selected ? .systemBlue : .secondarySystemBackground
        button.backgroundColor = background
        button.layer.cornerRadius = Self.cornerRadius
        button.layer.borderWidth = route.selected ? 0 : 1
        button.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        button.setTitle(Self.text(for: route.option), for: .normal)
        button.setTitleColor(route.selected ? .white : .label, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = "\(route.option.name), \(Format.duration(route.option.expectedSeconds)), \(Format.distance(route.option.distanceMetres))"
        button.accessibilityValue = route.selected ? "Selected" : "Not selected"
        button.accessibilityHint = "Select this route"
        button.accessibilityTraits = route.selected ? [.button, .selected] : .button
        button.accessibilityIdentifier = "mapRouteOption.\(route.option.id)"
        pointer.fillColor = background.resolvedColor(with: traitCollection).cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bodyHeight = bounds.height - Self.pointerHeight
        button.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bodyHeight)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.midX - Self.pointerHeight, y: bodyHeight - 1))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.height))
        path.addLine(to: CGPoint(x: bounds.midX + Self.pointerHeight, y: bodyHeight - 1))
        path.close()
        pointer.path = path.cgPath
    }

    @objc private func selectRoute() { onSelect?() }
}

@MainActor
enum RoutePreviewGeometry {
    static let tapTolerance: CGFloat = 22
    private static let fractions: [CGFloat] = [0.5, 0.35, 0.65, 0.2, 0.8, 0.1, 0.9,
                                               0.25, 0.75, 0.4, 0.6, 0.15, 0.85, 0.3, 0.7]

    static func distance(from point: CGPoint, to overlay: MKPolyline, on map: MKMapView) -> CGFloat? {
        distance(from: point, to: screenPoints(for: overlay, on: map))
    }

    static func place(_ annotations: [RoutePreviewAnnotation], on map: MKMapView) {
        guard map.bounds.width > 0, map.bounds.height > 0 else { return }
        let lines = annotations.map { screenPoints(for: $0.overlay, on: map) }
        let order = annotations.indices.sorted { annotations[$0].selected && !annotations[$1].selected }
        let visible = map.bounds.insetBy(dx: 8, dy: 8)
        var occupied: [CGRect] = []

        for index in order {
            let size = RoutePreviewAnnotationView.size(for: annotations[index].option)
            let choices = samples(along: lines[index])
            guard let point = choices.max(by: { first, second in
                score(first, size: size, visible: visible, occupied: occupied, lines: lines, excluding: index)
                    < score(second, size: size, visible: visible, occupied: occupied, lines: lines, excluding: index)
            }) else { continue }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            annotations[index].coordinate = coordinate
            occupied.append(labelRect(at: point, size: size))
        }
    }

    private static func screenPoints(for overlay: MKPolyline, on map: MKMapView) -> [CGPoint] {
        let points = overlay.points()
        return (0..<overlay.pointCount).map { map.convert(points[$0].coordinate, toPointTo: map) }
    }

    private static func distance(from point: CGPoint, to line: [CGPoint]) -> CGFloat? {
        guard let first = line.first else { return nil }
        var nearest = hypot(point.x - first.x, point.y - first.y)
        for (start, end) in zip(line, line.dropFirst()) {
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)) : 0
            nearest = min(nearest, hypot(point.x - start.x - t * dx, point.y - start.y - t * dy))
        }
        return nearest
    }

    private static func samples(along line: [CGPoint]) -> [CGPoint] {
        guard let first = line.first else { return [] }
        let segments = zip(line, line.dropFirst()).map { (start: $0, end: $1, length: hypot($1.x - $0.x, $1.y - $0.y)) }
        let total = segments.reduce(CGFloat.zero) { $0 + $1.length }
        guard total > 0 else { return [first] }
        return fractions.map { fraction in
            var remaining = total * fraction
            for segment in segments {
                if remaining <= segment.length, segment.length > 0 {
                    let t = remaining / segment.length
                    return CGPoint(x: segment.start.x + (segment.end.x - segment.start.x) * t,
                                   y: segment.start.y + (segment.end.y - segment.start.y) * t)
                }
                remaining -= segment.length
            }
            return line.last ?? first
        }
    }

    private static func labelRect(at point: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height, width: size.width, height: size.height)
    }

    private static func score(_ point: CGPoint, size: CGSize, visible: CGRect, occupied: [CGRect],
                              lines: [[CGPoint]], excluding index: Int) -> CGFloat {
        let rect = labelRect(at: point, size: size)
        let visiblePart = rect.intersection(visible)
        let visibleArea = visiblePart.isNull ? 0 : visiblePart.width * visiblePart.height
        let outside = rect.width * rect.height - visibleArea
        let overlap = occupied.reduce(CGFloat.zero) { total, other in
            let intersection = rect.insetBy(dx: -4, dy: -4).intersection(other)
            return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        let separation = lines.enumerated().filter { $0.offset != index }
            .compactMap { distance(from: point, to: $0.element) }.min() ?? 120
        return min(separation, 120) * 2 - outside * 10 - overlap * 20
    }
}
