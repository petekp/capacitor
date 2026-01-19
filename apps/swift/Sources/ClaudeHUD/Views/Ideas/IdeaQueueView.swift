import AppKit
import SwiftUI

struct IdeaQueueView: View {
    let ideas: [Idea]
    let isGeneratingTitle: (String) -> Bool
    var onTapIdea: ((Idea, CGRect) -> Void)?
    var onReorder: (([Idea]) -> Void)?
    var onRemove: ((Idea) -> Void)?

    @State private var localIdeas: [Idea] = []
    @State private var rowFrames: [String: CGRect] = [:]

    // Drag state
    @State private var draggingId: String?
    @State private var dragPosition: CGPoint = .zero
    @State private var dragStartPosition: CGPoint = .zero
    @State private var containerFrame: CGRect = .zero
    @State private var isAnimatingRelease = false

    @Environment(\.prefersReducedMotion) private var reduceMotion

    private let rowHeight: CGFloat = 48
    private let rowSpacing: CGFloat = 2

    private var queuedIdeas: [Idea] {
        localIdeas.filter { $0.status != "done" }
    }

    private var draggingIdea: Idea? {
        guard let draggingId else { return nil }
        return queuedIdeas.first { $0.id == draggingId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queuedIdeas.isEmpty {
                emptyState
            } else {
                queueListWithOverlay
            }
        }
        .onAppear {
            localIdeas = ideas
        }
        .onChange(of: ideas) { _, newValue in
            localIdeas = newValue
        }
    }

    private var queueListWithOverlay: some View {
        ZStack(alignment: .topLeading) {
            // Layer 1: The list (items animate freely here)
            queueList
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                containerFrame = geo.frame(in: .global)
                            }
                            .onChange(of: geo.frame(in: .global)) { _, newFrame in
                                containerFrame = newFrame
                            }
                    }
                )

            // Layer 2: The dragged item overlay
            if let idea = draggingIdea {
                IdeaQueueRow(
                    idea: idea,
                    isFirst: false,
                    isGeneratingTitle: isGeneratingTitle(idea.id),
                    onTap: nil,
                    onRemove: nil
                )
                .frame(height: rowHeight)
                .scaleEffect(isAnimatingRelease ? 1.0 : 1.03)
                .shadow(
                    color: .black.opacity(isAnimatingRelease ? 0 : 0.3),
                    radius: isAnimatingRelease ? 0 : 12,
                    y: isAnimatingRelease ? 0 : 4
                )
                .position(
                    x: containerFrame.width / 2,
                    y: dragPosition.y - containerFrame.minY
                )
                .animation(.spring(response: 0.3, dampingFraction: 1.0), value: dragPosition)
                .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isAnimatingRelease)
                .zIndex(1000)
                .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "queueContainer")
    }

    private var queueList: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(queuedIdeas.enumerated()), id: \.element.id) { index, idea in
                let isBeingDragged = draggingId == idea.id

                IdeaQueueRow(
                    idea: idea,
                    isFirst: index == 0 && !isBeingDragged,
                    isGeneratingTitle: isGeneratingTitle(idea.id),
                    onTap: {
                        if let frame = rowFrames[idea.id] {
                            onTapIdea?(idea, frame)
                        }
                    },
                    onRemove: onRemove != nil ? { onRemove?(idea) } : nil
                )
                .background(NonMovableBackground())
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                rowFrames[idea.id] = geo.frame(in: .global)
                            }
                            .onChange(of: geo.frame(in: .global)) { _, newFrame in
                                rowFrames[idea.id] = newFrame
                            }
                    }
                )
                // Hide the original when dragging (the overlay shows the dragged copy)
                .opacity(isBeingDragged ? 0 : 1)
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            handleDragChanged(idea: idea, globalPosition: value.location)
                        }
                        .onEnded { _ in
                            handleDragEnded()
                        }
                )
            }
        }
        // Now safe to animate - dragged item is in overlay, not here
        .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.9), value: queuedIdeas.map(\.id))
    }

    private func handleDragChanged(idea: Idea, globalPosition: CGPoint) {
        // Start dragging if not already
        if draggingId == nil {
            draggingId = idea.id
            // Record where the drag started (center of the row)
            if let frame = rowFrames[idea.id] {
                dragStartPosition = CGPoint(x: frame.midX, y: frame.midY)
            }
        }

        // Update drag position to follow cursor
        dragPosition = globalPosition

        // Calculate which slot the dragged item should move to
        let currentIndex = queuedIdeas.firstIndex { $0.id == idea.id } ?? 0
        let targetIndex = calculateTargetIndex(for: globalPosition)

        if targetIndex != currentIndex {
            moveItem(from: currentIndex, to: targetIndex)
        }
    }

    private func calculateTargetIndex(for position: CGPoint) -> Int {
        let rowPlusSpacing = rowHeight + rowSpacing

        // Calculate relative Y within the container
        let relativeY = position.y - containerFrame.minY

        // Which row slot does this Y position correspond to?
        let slotIndex = Int(relativeY / rowPlusSpacing)

        return max(0, min(queuedIdeas.count - 1, slotIndex))
    }

    private func moveItem(from sourceIndex: Int, to targetIndex: Int) {
        guard sourceIndex != targetIndex,
              sourceIndex >= 0, sourceIndex < queuedIdeas.count,
              targetIndex >= 0, targetIndex < queuedIdeas.count else {
            return
        }

        // Map queue indices to localIdeas indices
        let sourceId = queuedIdeas[sourceIndex].id
        let targetId = queuedIdeas[targetIndex].id

        guard let sourceLocalIndex = localIdeas.firstIndex(where: { $0.id == sourceId }),
              let targetLocalIndex = localIdeas.firstIndex(where: { $0.id == targetId }) else {
            return
        }

        // Move in the local array
        let destinationIndex = targetIndex > sourceIndex ? targetLocalIndex + 1 : targetLocalIndex
        localIdeas.move(fromOffsets: IndexSet(integer: sourceLocalIndex), toOffset: destinationIndex)
    }

    private func handleDragEnded() {
        guard let draggingId = draggingId else { return }

        // Find where the item will end up
        let targetIndex = queuedIdeas.firstIndex { $0.id == draggingId } ?? 0
        let rowPlusSpacing = rowHeight + rowSpacing
        let targetY = containerFrame.minY + (CGFloat(targetIndex) * rowPlusSpacing) + (rowHeight / 2)

        // Start release animation
        isAnimatingRelease = true
        dragPosition = CGPoint(x: dragPosition.x, y: targetY)

        // After animation completes, clean up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.draggingId = nil
            self.dragPosition = .zero
            self.isAnimatingRelease = false

            // Notify parent of final order
            let reorderedQueue = localIdeas.filter { $0.status != "done" }
            onReorder?(reorderedQueue)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No ideas in queue")
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(0.5))

            Text("Hover over the project card and click \"+ Idea\" to add one")
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Queue Row

struct IdeaQueueRow: View {
    let idea: Idea
    let isFirst: Bool
    let isGeneratingTitle: Bool
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
                .frame(width: 16)

            titleArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .overlay(alignment: .trailing) {
            if isHovered && !isGeneratingTitle {
                hoverActions
                    .padding(.trailing, 14)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(idea.title)
        .accessibilityHint(isFirst ? "Top of queue - next to work on" : "Drag to reorder")
    }

    private var titleArea: some View {
        ZStack(alignment: .leading) {
            Text(idea.title)
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(isFirst ? 0.9 : 0.7))
                .lineLimit(2)
                .opacity(isGeneratingTitle ? 0 : 1)

            if isGeneratingTitle {
                ShimmeringText(text: "Processing...")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isGeneratingTitle)
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 6) {
            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Remove idea")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: - Non-Movable Background

private struct NonMovableBackground: NSViewRepresentable {
    private class NonMovableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NonMovableNSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
