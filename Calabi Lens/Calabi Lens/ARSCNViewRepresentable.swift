//
//  ARSCNViewRepresentable.swift
//  Calabi Lens
//
//  Created by Chi Feng Chang on 2/19/26.
//

import SwiftUI
import ARKit

struct ARSCNViewRepresentable: UIViewRepresentable {

    @ObservedObject var manager: ARKitCaptureManager

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView()
        sceneView.session = manager.session
        sceneView.automaticallyUpdatesLighting = true
        sceneView.rendersCameraGrain = true
        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Session is managed by ARKitCaptureManager; no config changes needed here.
    }
}
