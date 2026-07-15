#pragma once
#import <CompositorServices/CompositorServices.h>

// Runs the visionOS immersive (3D) render loop until the layer is invalidated.
// Invoked from Q3EVisionApp.swift's CompositorLayer render closure on its own
// dedicated thread. See Q3EImmersive.m for the architecture.
void Q3E_Immersive_Run(cp_layer_renderer_t layer_renderer);
