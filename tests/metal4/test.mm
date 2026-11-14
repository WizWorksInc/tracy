#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "tracy/Tracy.hpp"
#include "tracy/TracyMetal4.hmm"

static bool WaitForProfiler( int seconds )
{
#ifdef TRACY_ENABLE
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds( seconds );
    while( !TracyIsConnected && std::chrono::steady_clock::now() < deadline )
    {
        std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
    }
    return TracyIsConnected;
#else
    (void)seconds;
    return false;
#endif
}

static void DrainProfiler()
{
#ifdef TRACY_ENABLE
    if( !TracyIsConnected ) return;
    tracy::GetProfiler().RequestShutdown();
    while( !tracy::GetProfiler().HasShutdownFinished() )
    {
        std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
    }
#endif
}

int main( int argc, char** argv )
{
    const int frames = argc > 1 ? atoi( argv[1] ) : 120;
    const int waitSeconds = argc > 2 ? atoi( argv[2] ) : 30;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if( device == nil || ![device supportsFamily:MTLGPUFamilyMetal4] )
    {
        fprintf( stderr, "Metal 4 is not available on this system.\n" );
        return 1;
    }

    const bool connected = WaitForProfiler( waitSeconds );
    printf( "profiler %s\n", connected ? "connected" : "not connected" );

    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
    id<MTLSharedEvent> frameDone = [device newSharedEvent];

    const NSUInteger bytes = 16u << 20;
    id<MTLBuffer> source = [device newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
    id<MTLBuffer> target = [device newBufferWithLength:bytes options:MTLResourceStorageModePrivate];

    MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    textureDescriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> color = [device newTextureWithDescriptor:textureDescriptor];

    NSError* error = nil;
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    [residency addAllocation:source];
    [residency addAllocation:target];
    [residency addAllocation:color];
    [residency commit];
    [queue addResidencySet:residency];

    NSString* shaderSource = @"#include <metal_stdlib>\n"
                              "using namespace metal;\n"
                              "struct VertexOut { float4 position [[position]]; };\n"
                              "vertex VertexOut vertexMain( uint vertexId [[vertex_id]] )\n"
                              "{\n"
                              "    VertexOut out;\n"
                              "    out.position = float4( float( ( vertexId << 1 ) & 2 ) * 2.0f - 1.0f, float( vertexId & 2 ) * 2.0f - 1.0f, 0.0f, 1.0f );\n"
                              "    return out;\n"
                              "}\n"
                              "fragment float4 fragmentMain( VertexOut in [[stage_in]] )\n"
                              "{\n"
                              "    float value = 0.0f;\n"
                              "    for( int i = 0; i < 64; i++ ) value += sin( in.position.x * float( i ) );\n"
                              "    return float4( value, 0.0f, 0.0f, 1.0f );\n"
                              "}\n";
    id<MTLLibrary> library = [device newLibraryWithSource:shaderSource options:nil error:&error];
    if( library == nil )
    {
        fprintf( stderr, "unable to build the shader library: %s\n", error.localizedDescription.UTF8String );
        return 1;
    }
    MTL4LibraryFunctionDescriptor* vertexFunction = [MTL4LibraryFunctionDescriptor new];
    vertexFunction.library = library;
    vertexFunction.name = @"vertexMain";
    MTL4LibraryFunctionDescriptor* fragmentFunction = [MTL4LibraryFunctionDescriptor new];
    fragmentFunction.library = library;
    fragmentFunction.name = @"fragmentMain";
    MTL4RenderPipelineDescriptor* pipelineDescriptor = [MTL4RenderPipelineDescriptor new];
    pipelineDescriptor.vertexFunctionDescriptor = vertexFunction;
    pipelineDescriptor.fragmentFunctionDescriptor = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
    id<MTLRenderPipelineState> pipeline = [compiler newRenderPipelineStateWithDescriptor:pipelineDescriptor compilerTaskOptions:nil error:&error];
    if( pipeline == nil )
    {
        fprintf( stderr, "unable to build the render pipeline: %s\n", error.localizedDescription.UTF8String );
        return 1;
    }

    TracyMetal4Ctx* ctx = TracyMetal4Context( device, queue );
    TracyMetal4ContextName( ctx, "Metal 4 test", 12 );
    (void)ctx;

    for( int frame = 0; frame < frames; frame++ )
    {
        @autoreleasepool
        {
            ZoneScopedN( "frame" );

            id<MTL4CommandBuffer> commandBuffer = [device newCommandBuffer];
            [commandBuffer beginCommandBufferWithAllocator:allocator];

            {
                TracyMetal4ZoneCS( ctx, commandBuffer, "copy pass", tracy::Color::SteelBlue, 8 );
                id<MTL4ComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                {
                    TracyMetal4Zone( ctx, encoder, "copy 16 MB" );
                    [encoder copyFromBuffer:source sourceOffset:0 toBuffer:target destinationOffset:0 size:bytes];
                }
                {
                    TracyMetal4NamedZoneC( ctx, copyBack, encoder, "copy back", tracy::Color::Khaki, true );
                    [encoder copyFromBuffer:target sourceOffset:0 toBuffer:source destinationOffset:0 size:bytes];
                }
                [encoder endEncoding];
            }

#ifdef TRACY_ENABLE
            {
                auto migrating = new tracy::Metal4ZoneScope( ctx, TracyLine, TracyFile, strlen( TracyFile ), TracyFunction, strlen( TracyFunction ), "migrating pass", 14, commandBuffer, true );
                id<MTL4ComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                [encoder copyFromBuffer:source sourceOffset:0 toBuffer:target destinationOffset:0 size:bytes];
                [encoder endEncoding];
                std::thread( [migrating] { delete migrating; } ).join();
            }
#endif

            {
                TracyMetal4ZoneTransient( ctx, drawPass, commandBuffer, ( frame & 1 ) ? "draw pass (odd)" : "draw pass (even)", true );
                TracyMetal4NamedZone( ctx, inactive, commandBuffer, "inactive", false );
                MTL4RenderPassDescriptor* pass = [MTL4RenderPassDescriptor new];
                pass.colorAttachments[0].texture = color;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTL4RenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
                [encoder setRenderPipelineState:pipeline];
                [encoder setViewport:MTLViewport{ 0.0, 0.0, 1024.0, 1024.0, 0.0, 1.0 }];
                {
                    TracyMetal4ZoneC( ctx, encoder, "draw", tracy::Color::Tomato );
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                [encoder endEncoding];
            }

            [commandBuffer endCommandBuffer];
            [queue commit:&commandBuffer count:1];
            [queue signalEvent:frameDone value:uint64_t( frame ) + 1];

            TracyMetal4Collect( ctx );
            FrameMark;

            // The allocator is reset only once the GPU has finished with its command buffer.
            while( frameDone.signaledValue < uint64_t( frame ) + 1 )
            {
                std::this_thread::sleep_for( std::chrono::microseconds( 200 ) );
            }
            [allocator reset];
        }
        std::this_thread::sleep_for( std::chrono::milliseconds( 4 ) );
    }

    TracyMetal4Destroy( ctx );
    DrainProfiler();
    printf( "done\n" );
    return 0;
}
