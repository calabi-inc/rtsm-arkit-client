//
//  ContentView.swift
//  Calabi Lens
//
//  Created by Chi Feng Chang on 2/19/26.
//

import SwiftUI
import ARKit

struct ContentView: View {
    @State private var appState: AppState = .idle
    @StateObject private var captureManager = ARKitCaptureManager()

    var body: some View {
        ZStack {
            ARSCNViewRepresentable(manager: captureManager)
                .ignoresSafeArea()

            VStack {
                Spacer()
                trackingLabel
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            captureManager.run()
            appState = .capturing
        }
        .onDisappear {
            captureManager.pause()
            appState = .idle
        }
    }

    private var trackingLabel: some View {
        Text(trackingText)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var trackingText: String {
        switch captureManager.trackingState {
        case .notAvailable:
            return "Tracking Unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "Initializing..."
            case .excessiveMotion:
                return "Too Much Motion"
            case .insufficientFeatures:
                return "Low Detail"
            case .relocalizing:
                return "Relocalizing..."
            @unknown default:
                return "Limited Tracking"
            }
        case .normal:
            return "Tracking Normal"
        }
    }
}

#Preview {
    ContentView()
}
