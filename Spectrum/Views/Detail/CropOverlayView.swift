import SwiftUI

struct CropOverlayView: View {
    @Binding var cropRect: CGRect // normalised 0~1
    let imagePixelWidth: Int
    let imagePixelHeight: Int
    let hasExistingCrop: Bool
    var onApply: () -> Void
    var onCancel: () -> Void
    var onRestore: () -> Void

    private let handleSize: CGFloat = 14
    private let edgeBarLen: CGFloat = 32
    private let hitArea: CGFloat = 36
    private let minFraction: CGFloat = 0.05
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Dark mask (even-odd)
                maskPath(in: size)
                    .fill(style: FillStyle(eoFill: true))
                    .foregroundStyle(.black.opacity(0.5))
                    .allowsHitTesting(false)

                // White border
                cropBorder(in: size).allowsHitTesting(false)

                // Rule-of-thirds lines
                thirdLines(in: size).allowsHitTesting(false)

                // Move gesture (inside crop area)
                moveArea(in: size)

                // Handle marks (visual only)
                handleMarksPath(in: size)
                    .stroke(.white, lineWidth: 3)
                    .allowsHitTesting(false)

                // Corner hit areas (drag only)
                cornerHitArea(.topLeading, in: size)
                cornerHitArea(.topTrailing, in: size)
                cornerHitArea(.bottomLeading, in: size)
                cornerHitArea(.bottomTrailing, in: size)

                // Edge hit areas (drag only)
                edgeHitArea(.top, in: size)
                edgeHitArea(.bottom, in: size)
                edgeHitArea(.leading, in: size)
                edgeHitArea(.trailing, in: size)

                // Bottom bar
                VStack {
                    Spacer()
                    bottomBar.padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Pixel rect helper

    private func cropPixelRect(in size: CGSize) -> CGRect {
        CGRect(
            x: cropRect.minX * size.width,
            y: cropRect.minY * size.height,
            width: cropRect.width * size.width,
            height: cropRect.height * size.height
        )
    }

    // MARK: - Visuals

    private func maskPath(in size: CGSize) -> Path {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRect(cropPixelRect(in: size))
        }
    }

    @ViewBuilder
    private func cropBorder(in size: CGSize) -> some View {
        let r = cropPixelRect(in: size)
        Rectangle()
            .stroke(.white, lineWidth: 1.5)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
    }

    @ViewBuilder
    private func thirdLines(in size: CGSize) -> some View {
        let r = cropPixelRect(in: size)
        Path { p in
            for i in 1...2 {
                let fx = r.minX + r.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: fx, y: r.minY))
                p.addLine(to: CGPoint(x: fx, y: r.maxY))
                let fy = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: r.minX, y: fy))
                p.addLine(to: CGPoint(x: r.maxX, y: fy))
            }
        }
        .stroke(.white.opacity(0.3), lineWidth: 0.5)
    }

    // MARK: - Move gesture

    @ViewBuilder
    private func moveArea(in size: CGSize) -> some View {
        let r = cropPixelRect(in: size)
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = cropRect }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / size.width
                        let dy = value.translation.height / size.height
                        let newX = max(0, min(1 - start.width, start.minX + dx))
                        let newY = max(0, min(1 - start.height, start.minY + dy))
                        cropRect = CGRect(x: newX, y: newY, width: start.width, height: start.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    // MARK: - Corner handles

    private enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func cornerPos(_ c: Corner) -> CGPoint {
        switch c {
        case .topLeading:     return CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .topTrailing:    return CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .bottomLeading:  return CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottomTrailing: return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }
    }

    private func handleMarksPath(in size: CGSize) -> Path {
        let r = cropPixelRect(in: size)
        let l = handleSize
        let half = edgeBarLen / 2
        return Path { p in
            // topLeading
            p.move(to: CGPoint(x: r.minX, y: r.minY + l))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
            // topTrailing
            p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
            // bottomLeading
            p.move(to: CGPoint(x: r.minX, y: r.maxY - l))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
            // bottomTrailing
            p.move(to: CGPoint(x: r.maxX - l, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
            // top edge bar
            p.move(to: CGPoint(x: r.midX - half, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX + half, y: r.minY))
            // bottom edge bar
            p.move(to: CGPoint(x: r.midX - half, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX + half, y: r.maxY))
            // leading edge bar
            p.move(to: CGPoint(x: r.minX, y: r.midY - half))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY + half))
            // trailing edge bar
            p.move(to: CGPoint(x: r.maxX, y: r.midY - half))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY + half))
        }
    }

    @ViewBuilder
    private func cornerHitArea(_ corner: Corner, in size: CGSize) -> some View {
        let pos = cornerPos(corner)
        Circle()
            .fill(.clear)
            .contentShape(Circle())
            .frame(width: hitArea, height: hitArea)
            .position(x: pos.x * size.width, y: pos.y * size.height)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = cropRect }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / size.width
                        let dy = value.translation.height / size.height
                        cropRect = adjustCorner(start, corner: corner, dx: dx, dy: dy)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func adjustCorner(_ s: CGRect, corner: Corner, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch corner {
        case .topLeading:
            let x = max(0, min(s.maxX - minFraction, s.minX + dx))
            let y = max(0, min(s.maxY - minFraction, s.minY + dy))
            return CGRect(x: x, y: y, width: s.maxX - x, height: s.maxY - y)
        case .topTrailing:
            let mx = max(s.minX + minFraction, min(1, s.maxX + dx))
            let y  = max(0, min(s.maxY - minFraction, s.minY + dy))
            return CGRect(x: s.minX, y: y, width: mx - s.minX, height: s.maxY - y)
        case .bottomLeading:
            let x  = max(0, min(s.maxX - minFraction, s.minX + dx))
            let my = max(s.minY + minFraction, min(1, s.maxY + dy))
            return CGRect(x: x, y: s.minY, width: s.maxX - x, height: my - s.minY)
        case .bottomTrailing:
            let mx = max(s.minX + minFraction, min(1, s.maxX + dx))
            let my = max(s.minY + minFraction, min(1, s.maxY + dy))
            return CGRect(x: s.minX, y: s.minY, width: mx - s.minX, height: my - s.minY)
        }
    }

    // MARK: - Edge handles

    private enum Edge: CaseIterable { case top, trailing, bottom, leading }

    private func edgePos(_ e: Edge) -> CGPoint {
        switch e {
        case .top:      return CGPoint(x: cropRect.midX, y: cropRect.minY)
        case .trailing: return CGPoint(x: cropRect.maxX, y: cropRect.midY)
        case .bottom:   return CGPoint(x: cropRect.midX, y: cropRect.maxY)
        case .leading:  return CGPoint(x: cropRect.minX, y: cropRect.midY)
        }
    }

    @ViewBuilder
    private func edgeHitArea(_ edge: Edge, in size: CGSize) -> some View {
        let pos = edgePos(edge)
        let isHorizontal = edge == .top || edge == .bottom
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(
                width:  isHorizontal ? hitArea * 1.5 : hitArea * 0.7,
                height: isHorizontal ? hitArea * 0.7 : hitArea * 1.5
            )
            .position(x: pos.x * size.width, y: pos.y * size.height)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = cropRect }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / size.width
                        let dy = value.translation.height / size.height
                        cropRect = adjustEdge(start, edge: edge, dx: dx, dy: dy)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func adjustEdge(_ s: CGRect, edge: Edge, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch edge {
        case .top:
            let y = max(0, min(s.maxY - minFraction, s.minY + dy))
            return CGRect(x: s.minX, y: y, width: s.width, height: s.maxY - y)
        case .bottom:
            let my = max(s.minY + minFraction, min(1, s.maxY + dy))
            return CGRect(x: s.minX, y: s.minY, width: s.width, height: my - s.minY)
        case .leading:
            let x = max(0, min(s.maxX - minFraction, s.minX + dx))
            return CGRect(x: x, y: s.minY, width: s.maxX - x, height: s.height)
        case .trailing:
            let mx = max(s.minX + minFraction, min(1, s.maxX + dx))
            return CGRect(x: s.minX, y: s.minY, width: mx - s.minX, height: s.height)
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        let pw = Int(Double(imagePixelWidth) * cropRect.width)
        let ph = Int(Double(imagePixelHeight) * cropRect.height)

        HStack(spacing: 12) {
            Text("\(pw) \u{00d7} \(ph)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if hasExistingCrop {
                Button("Restore") { onRestore() }
            }

            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)

            Button("Apply") { onApply() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420)
    }
}
