// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// One update-state subscription per row or detail pane; the content reads its presentation.
struct ObservedUpdatePresentation<Content: View>: View {
  let app: App
  let updating: any AppUpdating
  @ViewBuilder let content: (UpdateActionPresentation) -> Content
  @State private var observed: ObservedState?

  private struct ObservationKey: Equatable {
    let app: App.Bundle.Identifier
    let instance: ObjectIdentifier
    let service: ObjectIdentifier
  }

  private struct ObservedState {
    let key: ObservationKey
    let presentation: UpdateActionPresentation
  }

  private var key: ObservationKey {
    ObservationKey(
      app: app.identifier, instance: ObjectIdentifier(app), service: ObjectIdentifier(updating))
  }

  private var presentation: UpdateActionPresentation {
    if let observed, observed.key == key { return observed.presentation }
    return .make(for: app, progressState: updating.state(for: app.identifier))
  }

  var body: some View {
    content(presentation)
      .task(id: key) {
        let key = key
        for await state in updating.states(for: app.identifier) {
          guard !Task.isCancelled else { return }
          let next = ObservedState(key: key, presentation: .make(for: app, progressState: state))
          if observed?.key != key || observed?.presentation != next.presentation { observed = next }
        }
      }
  }
}

/// The row's trailing control: an Update/Open button like the App Store's, or progress in place.
struct SidebarUpdateStatus: View {
  let app: App
  let presentation: UpdateActionPresentation
  let selection: UpdateRowSelection
  let updating: any AppUpdating
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.compactLayout) private var compact

  var body: some View {
    switch presentation {
    case .update where compact:
      EmptyView()
    case .update:
      Button(SidebarUpdateActionTitle.shortText(for: app)) { updating.update(app) }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help(app.updateExplanation)
        .accessibilityLabel(SidebarUpdateActionTitle.text(for: app))
        .accessibilityIdentifier("updates.action")
    case .open:
      EmptyView()
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(
          selection.usesActiveSelectionColors
            ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .systemOrange)
        )
        .accessibilityLabel("Update failed")
    case .retryTermination:
      Button {
        updating.retryTermination(app)
      } label: {
        Image(systemName: "arrow.clockwise")
          .foregroundStyle(
            Color(
              nsColor: selection.usesActiveSelectionColors
                ? .alternateSelectedControlTextColor : .controlAccentColor))
      }
      .buttonStyle(.plain)
      .frame(width: 24, height: 24)
      .help("Save your work, then retry quitting \(app.name) to finish the update.")
      .accessibilityLabel("Retry quitting \(app.name)")
      .accessibilityIdentifier("updates.retry-termination")
    case .waiting(let status):
      TimelineView(.animation(paused: reduceMotion)) { context in
        SidebarIndicatorGlyph(
          fraction: nil,
          angle: reduceMotion
            ? 0
            : context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: 1) * 360,
          tint: Color(
            nsColor: selection.usesActiveSelectionColors
              ? .alternateSelectedControlTextColor : .tertiaryLabelColor))
      }
      .frame(width: 24, height: 24)
      .help(status)
      .accessibilityLabel(status)
    case .progress(_, let status, let cancellable):
      if !compact {
        StopCapsule(enabled: cancellable, identifier: "updates.progress", status: status) {
          updating.cancel(app)
        }
      }
    }
  }
}

/// Uses the original 24-point control's paths and backing-pixel alignment.
private struct SidebarIndicatorGlyph: View, Animatable {
  var fraction: Double?
  let angle: Double
  let tint: Color
  @Environment(\.displayScale) private var displayScale
  @Environment(\.self) private var environment

  var animatableData: Double {
    get { fraction ?? 0 }
    set { if fraction != nil { fraction = newValue } }
  }

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let radius = size.height * 0.4
      context.withCGContext { cg in
        let resolvedTint = tint.resolve(in: environment).cgColor
        cg.setLineWidth(2.5)
        if let fraction {
          let minX = floor((center.x - radius) * displayScale) / displayScale
          let minY = floor((center.y - radius) * displayScale) / displayScale
          let maxX = ceil((center.x + radius) * displayScale) / displayScale
          let maxY = ceil((center.y + radius) * displayScale) / displayScale
          cg.setStrokeColor(Color(nsColor: .tertiaryLabelColor).resolve(in: environment).cgColor)
          cg.addPath(
            SidebarIndicatorPaths.ring(
              in: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            )
            .cgPath)
          cg.strokePath()
          cg.setFillColor(resolvedTint)
          guard fraction > 0 else { return }
        }
        cg.setLineCap(.round)
        cg.setStrokeColor(resolvedTint)
        let arc = SidebarIndicatorPaths.arc(
          center: center, radii: CGSize(width: radius, height: radius), angle: angle,
          sweep: fraction.map { $0 * 360 } ?? 270)
        cg.addPath(arc.cgPath)
        cg.strokePath()
      }
    }
  }
}

/// SwiftUI paths with the original cubic curves. Building the backing CGPath
/// keeps double precision; Path's mutating builders round points to Float.
enum SidebarIndicatorPaths {
  static func ring(in rect: CGRect) -> Path {
    arc(
      center: CGPoint(x: rect.midX, y: rect.midY),
      radii: CGSize(width: rect.width / 2, height: rect.height / 2), angle: -45, sweep: 360)
  }

  static func arc(center: CGPoint, radii: CGSize, angle: Double, sweep: Double) -> Path {
    let path = CGMutablePath()
    var theta = angle * .pi / 180
    let end = (angle + sweep) * .pi / 180
    func point(_ angle: Double) -> CGPoint {
      CGPoint(
        x: center.x + radii.width * cos(angle), y: center.y + radii.height * sin(angle))
    }
    path.move(to: point(theta))
    while theta < end {
      let next = min(theta + .pi / 2, end)
      let tangent = 4 / 3.0 * tan((next - theta) / 4)
      let startPoint = point(theta)
      let endPoint = point(next)
      path.addCurve(
        to: endPoint,
        control1: CGPoint(
          x: startPoint.x - radii.width * sin(theta) * tangent,
          y: startPoint.y + radii.height * cos(theta) * tangent),
        control2: CGPoint(
          x: endPoint.x + radii.width * sin(next) * tangent,
          y: endPoint.y - radii.height * cos(next) * tangent))
      theta = next
    }
    return Path(path)
  }
}
