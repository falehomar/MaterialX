//
// Copyright Contributors to the MaterialX Project
// SPDX-License-Identifier: Apache-2.0
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <unistd.h>
#include "Viewer.h"
#include "RenderPipelineMetal.h"
#include <MaterialXFormat/Util.h>

@interface MetalView : NSView <NSWindowDelegate>
{
    CAMetalLayer* _metalLayer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _cmdQueue;
    Viewer* _viewer;
    CVDisplayLinkRef _displayLink;
    BOOL _initialized;
}

- (instancetype)initWithFrame:(NSRect)frame viewer:(Viewer*)viewer device:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)cmdQueue;
- (void)drawFrame;
@end

@implementation MetalView

- (instancetype)initWithFrame:(NSRect)frame viewer:(Viewer*)viewer device:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)cmdQueue
{
    self = [super initWithFrame:frame];
    if (self) {
        _viewer = viewer;
        _device = device;
        _cmdQueue = cmdQueue;
        
        [self setWantsLayer:YES];
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = _device;
        _metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
        _metalLayer.framebufferOnly = NO; // support read-back
        _metalLayer.opaque = YES;
        [self setLayer:_metalLayer];
        
        _viewer->m_pixel_ratio = [[NSScreen mainScreen] backingScaleFactor];
        
        // Setup display link for rendering loop
        CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
        CVDisplayLinkSetOutputCallback(_displayLink, &DisplayLinkCallback, (__bridge void*)self);
        CVDisplayLinkStart(_displayLink);
        
        _initialized = YES;
    }
    return self;
}

- (void)dealloc
{
    CVDisplayLinkStop(_displayLink);
    CVDisplayLinkRelease(_displayLink);
    [super dealloc];
}

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now, const CVTimeStamp* outputTime,
                                    CVOptionFlags flagsIn, CVOptionFlags* flagsOut, void* displayLinkContext)
{
    @autoreleasepool {
        MetalView* view = (__bridge MetalView*)displayLinkContext;
        [view drawFrame];
    }
    return kCVReturnSuccess;
}

- (void)drawFrame
{
    if (!_initialized) return;
    
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) return;
    
    _viewer->m_size = mx::Vector2(self.bounds.size.width, self.bounds.size.height);
    _viewer->setColorTexture((__bridge void*)drawable.texture);
    _viewer->draw_contents();
    
    id<MTLCommandBuffer> cmdBuf = [_cmdQueue commandBuffer];
    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

- (void)windowWillClose:(NSNotification *)notification
{
    [NSApp terminate:nil];
}

@end

extern "C" {
    #ifdef _WIN32
    #define EXPORT __declspec(dllexport)
    #else
    #define EXPORT __attribute__((visibility("default")))
    #endif

    EXPORT int runViewer(int argc, char* const argv[]);
}

EXPORT int runViewer(int argc, char* const argv[])
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        
        // Parse command line arguments similar to the original ViewerRunner
        std::vector<std::string> tokens;
        for (int i = 1; i < argc; i++)
        {
            tokens.emplace_back(argv[i]);
        }

        std::string materialFilename = "resources/Materials/Examples/StandardSurface/standard_surface_default.mtlx";
        std::string meshFilename = "resources/Geometry/shaderball.glb";
        std::string envRadianceFilename = "resources/Lights/san_giuseppe_bridge_split.hdr";
        
        // Retrieve the current working directory or check if resources exist
        mx::FileSearchPath searchPath;
        char* cwdRaw = getcwd(nullptr, 0);
        if (cwdRaw)
        {
            std::string cwd(cwdRaw);
            free(cwdRaw);
            searchPath.append(mx::FileSearchPath(cwd));
            // Add fallback paths to search path
            searchPath.append(mx::FileSearchPath(cwd + "/resources"));
            searchPath.append(mx::FileSearchPath(cwd + "/libraries"));
        }
        searchPath.append(mx::getDefaultDataSearchPath());
        
        mx::FilePathVec libraryFolders;

        mx::Vector3 meshRotation;
        float meshScale = 1.0f;
        bool turntableEnabled = false;
        int turntableSteps = 360;
        mx::Vector3 cameraPosition(DEFAULT_CAMERA_POSITION);
        mx::Vector3 cameraTarget;
        float cameraViewAngle(DEFAULT_CAMERA_VIEW_ANGLE);
        float cameraZoom(DEFAULT_CAMERA_ZOOM);
        mx::HwSpecularEnvironmentMethod specularEnvironmentMethod = mx::SPECULAR_ENVIRONMENT_FIS;
        int envSampleCount = mx::DEFAULT_ENV_SAMPLE_COUNT;
        float envLightIntensity = 1.0f;
        float lightRotation = 0.0f;
        bool enableDirectLight = true;
        bool shadowMap = true;
        DocumentModifiers modifiers;
        int screenWidth = 1280;
        int screenHeight = 960;
        mx::Color3 screenColor(mx::DEFAULT_SCREEN_COLOR_SRGB);
        bool drawEnvironment = true;
        std::string captureFilename;
        int bakeWidth = 0;
        int bakeHeight = 0;
        std::string bakeFilename;
        float refresh = 50.0f;
        bool frameTiming = false;
        bool renderSimpleCube = false;

        for (size_t i = 0; i < tokens.size(); i++)
        {
            const std::string& token = tokens[i];
            const std::string& nextToken = i + 1 < tokens.size() ? tokens[i + 1] : mx::EMPTY_STRING;
            if (token == "--material")
            {
                materialFilename = nextToken;
            }
            else if (token == "--mesh")
            {
                meshFilename = nextToken;
            }
            else if (token == "--envRad")
            {
                envRadianceFilename = nextToken;
            }
            else if (token == "--path")
            {
                searchPath.append(mx::FileSearchPath(nextToken));
            }
            else if (token == "--library")
            {
                libraryFolders.push_back(nextToken);
            }
            else if (token == "--screenWidth")
            {
                screenWidth = std::stoi(nextToken);
            }
            else if (token == "--screenHeight")
            {
                screenHeight = std::stoi(nextToken);
            }
            else if (token == "--cube")
            {
                renderSimpleCube = true;
            }
            else if (token == "--drawEnvironment")
            {
                drawEnvironment = (nextToken == "true" || nextToken == "1");
            }
            
            if (!nextToken.empty() && token != "--cube")
            {
                i++;
            }
        }

        libraryFolders.push_back("libraries");

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];

        Viewer* viewer = new Viewer(materialFilename,
                                    meshFilename,
                                    envRadianceFilename,
                                    searchPath,
                                    libraryFolders,
                                    screenWidth,
                                    screenHeight,
                                    screenColor);
        viewer->setRenderSimpleCube(renderSimpleCube);
        viewer->setMeshRotation(meshRotation);
        viewer->setMeshScale(meshScale);
        viewer->setTurntableEnabled(turntableEnabled);
        viewer->setTurntableSteps(turntableSteps);
        viewer->setCameraPosition(cameraPosition);
        viewer->setCameraTarget(cameraTarget);
        viewer->setCameraViewAngle(cameraViewAngle);
        viewer->setCameraZoom(cameraZoom);
        viewer->setSpecularEnvironmentMethod(specularEnvironmentMethod);
        viewer->setEnvSampleCount(envSampleCount);
        viewer->setEnvLightIntensity(envLightIntensity);
        viewer->setLightRotation(lightRotation);
        viewer->setDirectLightEnable(enableDirectLight);
        viewer->setShadowMapEnable(shadowMap);
        viewer->setDrawEnvironment(drawEnvironment);
        viewer->setDocumentModifiers(modifiers);
        viewer->setBakeWidth(bakeWidth);
        viewer->setBakeHeight(bakeHeight);
        viewer->setBakeFilename(bakeFilename);
        viewer->setFrameTiming(frameTiming);
        
        // Initialize Render Pipeline with Cocoa device and queue
        viewer->getRenderPipeline()->initialize((__bridge void*)device, (__bridge void*)queue);
        viewer->initialize();

        NSRect frame = NSMakeRect(0, 0, screenWidth, screenHeight);
        NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"MaterialX native macOS Viewer"];
        
        MetalView* view = [[MetalView alloc] initWithFrame:frame viewer:viewer device:device commandQueue:queue];
        [window setContentView:view];
        [window setDelegate:view];
        [window makeKeyAndOrderFront:nil];
        [window center];
        
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}
