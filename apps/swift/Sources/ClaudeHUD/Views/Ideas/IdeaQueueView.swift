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
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false

    @Environment(\.prefersReducedMotion) private var reduceMotion

    private let rowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 2

    private var queuedIdeas: [Idea] {
        localIdeas.filter { $0.status != "done" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queuedIdeas.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .onAppear {
            localIdeas = ideas
        }
        .onChange(of: ideas) { _, newValue in
            localIdeas = newValue
        }
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
                // Only the dragged item gets offset
                .offset(y: isBeingDragged ? dragTranslation : 0)
                .zIndex(isBeingDragged ? 100 : 0)
                .scaleEffect(isBeingDragged ? 1.02 : 1.0)
                .opacity(isBeingDragged ? 0.9 : 1.0)
                .shadow(
                    color: .black.opacity(isBeingDragged ? 0.25 : 0),
                    radius: isBeingDragged ? 8 : 0,
                    y: isBeingDragged ? 2 : 0
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            handleDragChanged(idea: idea, currentIndex: index, translation: value.translation.height)
                        }
                        .onEnded { _ in
                            handleDragEnded()
                        }
                )
            }
        }
    }

    private func handleDragChanged(idea: Idea, currentIndex: Int, translation: CGFloat) {
        // Start dragging if not already
        if draggingId == nil {
            draggingId = idea.id
            isDragging = true
        }

        dragTranslation = translation

        // Calculate if we should swap with another item
        let threshold = rowHeight / 2
        let rowPlusSpacing = rowHeight + rowSpacing

        // Find where in the list the dragged item currently appears
        guard let currentArrayIndex = queuedIdeas.firstIndex(where: { $0.id == idea.id }) else { return }

        // Check if we should move up
        if translation < -threshold && currentArrayIndex > 0 {
            let targetIndex = currentArrayIndex - 1
            swapItems(from: currentArrayIndex, to: targetIndex)
            // Adjust translation so item stays under cursor
            dragTranslation += rowPlusSpacing
        }
        // Check if we should move down
        else if translation > threshold && currentArrayIndex < queuedIdeas.count - 1 {
            let targetIndex = currentArrayIndex + 1
            swapItems(from: currentArrayIndex, to: targetIndex)
            // Adjust translation so item stays under cursor
            dragTranslation -= rowPlusSpacing
        }
    }

    private func swapItems(from sourceIndex: Int, to targetIndex: Int) {
        // Map queue indices to localIdeas indices
        let sourceId = queuedIdeas[sourceIndex].id
        let targetId = queuedIdeas[targetIndex].id

        guard let sourceLocalIndex = localIdeas.firstIndex(where: { $0.id == sourceId }),
              let targetLocalIndex = localIdeas.firstIndex(where: { $0.id == targetId }) else {
            return
        }

        // Swap in the local array (no animation during drag to prevent jitter)
        localIdeas.swapAt(sourceLocalIndex, targetLocalIndex)
    }

    private func handleDragEnded() {
        // Animate the dragged item back to its layout position
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            dragTranslation = 0
            draggingId = nil
            isDragging = false
        }

        // Notify parent of final order
        let reorderedQueue = localIdeas.filter { $0.status != "done" }
        onReorder?(reorderedQueue)
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
        .padding(.vertical, 10)
        .frame(height: 44)
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
