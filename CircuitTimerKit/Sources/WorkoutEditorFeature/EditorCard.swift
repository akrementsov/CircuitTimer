import DesignSystem
import SwiftUI

/// One section of the workout screen on a single card, like the original screen's section background: rows coming
/// and going inside it change only its height, so the screen never shows through the card.
struct EditorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
        VStack(spacing: .zero) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(.surface(.card), in: shape)
        // A swiped row slides out under the card's edge, as in the original app.
        .clipShape(shape)
    }
}

/// A whole card coming or going: it opens from its top edge with its corners rounded, instead of fading in over the
/// screen.
struct PlaqueReveal: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(PlaqueRevealMask(progress: phase.isIdentity ? 1 : 0))
    }
}

private struct PlaqueRevealMask: ViewModifier, Animatable {
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: .token(radius: .m), style: .continuous)
                    .frame(height: proxy.size.height * progress)
            }
        }
    }
}

extension View {
    /// A row that exists only while editing: read-only it keeps its place in the card at zero height, so the card
    /// grows and shrinks around it instead of a new row fading in.
    func phaseCollapsed(_ collapsed: Bool) -> some View {
        frame(height: collapsed ? .zero : nil, alignment: .top)
            .clipped()
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}

#Preview {
    @Previewable @State var isExpanded = false
    VStack(spacing: .token(spacing: .m)) {
        EditorCard {
            Text(verbatim: "Always")
                .padding(.token(spacing: .l))
            Text(verbatim: "Collapses")
                .padding(.token(spacing: .l))
                .phaseCollapsed(!isExpanded)
        }
        if isExpanded {
            EditorCard {
                Text(verbatim: "Comes and goes")
                    .padding(.token(spacing: .l))
            }
            .transition(PlaqueReveal())
        }
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { isExpanded.toggle() }
        } label: {
            Text(verbatim: "Toggle")
        }
    }
    .foregroundStyle(.text(.primary))
    .padding(.token(spacing: .l))
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.surface(.screen))
    .preferredColorScheme(.dark)
}
