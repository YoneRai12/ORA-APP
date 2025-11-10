import SwiftUI
import UIKit

struct DrawerHost<Menu: View, Content: View>: View {
    let drawerWidth: CGFloat
    @Binding var isOpen: Bool
    @ViewBuilder var menu: () -> Menu
    @ViewBuilder var content: () -> Content

    @GestureState private var drag: CGFloat = 0
    @State private var base: CGFloat = 0

    init(drawerWidth: CGFloat = 320,
         isOpen: Binding<Bool>,
         @ViewBuilder menu: @escaping () -> Menu,
         @ViewBuilder content: @escaping () -> Content) {
        self.drawerWidth = drawerWidth
        self._isOpen = isOpen
        self.menu = menu
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .scaleEffect(isOpen ? 0.98 : 1)
                .overlay {
                    if isOpen {
                        Color.black.opacity(0.25).ignoresSafeArea()
                            .onTapGesture { withAnimation(.spring) { isOpen = false } }
                    }
                }

            menu()
                .frame(width: drawerWidth)
                .background(LiquidGlassBackground())
                .offset(x: -drawerWidth + currentOffset)
                .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
                .accessibilityHidden(!isOpen)
        }
        .gesture(dragGesture)
        .simultaneousGesture(edgeGesture)
        .onChange(of: isOpen) { _, open in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                base = open ? drawerWidth : 0
            }
        }
    }

    private var currentOffset: CGFloat {
        min(max(base + drag, 0), drawerWidth)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .updating($drag) { value, state, _ in state = value.translation.width }
            .onChanged { _ in base = isOpen ? drawerWidth : 0 }
            .onEnded { value in
                let end = base + value.translation.width
                let open = end > drawerWidth * 0.45 || value.predictedEndTranslation.width > 120
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    isOpen = open
                    base = open ? drawerWidth : 0
                }
                haptics(open)
            }
    }

    private var edgeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if !isOpen && value.startLocation.x < 20 && value.translation.width > 0 {
                    withAnimation(.easeOut(duration: 0.1)) { base = min(value.translation.width, drawerWidth) }
                }
            }
            .onEnded { _ in
                let open = base > drawerWidth * 0.35
                withAnimation(.spring) {
                    isOpen = open
                    base = open ? drawerWidth : 0
                }
                haptics(open)
            }
    }

    private func haptics(_ open: Bool) {
        #if canImport(UIKit)
        if open { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        #endif
    }
}
