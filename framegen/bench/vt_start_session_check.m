// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Shows the trap behind "Processor is not initialized": for a picture the system does not
// accept (over 921600 pixels on macOS 26.2), startSessionWithConfiguration returns YES and
// reports the reason only in the NSError; every later process call then fails.
//
// build: clang -fobjc-arc -mmacosx-version-min=26.0 -O2 vt_start_session_check.m -o vt_start_session_check \
//          -framework Foundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework Metal
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>
#import <VideoToolbox/VTFrameProcessor_FrameRateConversion.h>
#include <unistd.h>

static CVPixelBufferRef mk(NSDictionary *attrs, uint8_t luma)
{
	CVPixelBufferRef pb = NULL;
	int w = [attrs[(id)kCVPixelBufferWidthKey] intValue], h = [attrs[(id)kCVPixelBufferHeightKey] intValue];
	CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)attrs, &pb);
	if(!pb)
		return NULL;
	CVPixelBufferLockBaseAddress(pb, 0);
	for(int p = 0; p < 2; p++)
	{
		uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(pb, p);
		size_t s = CVPixelBufferGetBytesPerRowOfPlane(pb, p), rows = CVPixelBufferGetHeightOfPlane(pb, p);
		memset(b, p == 0 ? luma : 128, s * rows);
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
	return pb;
}

static void try_size(int w, int h)
{
	printf("\n== low-latency interpolation %dx%d\n", w, h);
	VTLowLatencyFrameInterpolationConfiguration *cfg =
		[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];
	if(!cfg)
	{
		printf("config nil\n");
		return;
	}
	VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
	NSError *err = nil;
	BOOL ok = [proc startSessionWithConfiguration:cfg error:&err];
	printf("startSession returned %d, error: %s\n", (int)ok, err ? [[err description] UTF8String] : "(none)");
	CVPixelBufferRef a = mk(cfg.sourcePixelBufferAttributes, 60), b = mk(cfg.sourcePixelBufferAttributes, 90);
	for(int attempt = 0; attempt < 6; attempt++)
	{
		CVPixelBufferRef d = mk(cfg.destinationPixelBufferAttributes, 0);
		VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:a presentationTimeStamp:CMTimeMake(attempt * 20, 600)];
		VTFrameProcessorFrame *fs = [[VTFrameProcessorFrame alloc] initWithBuffer:b presentationTimeStamp:CMTimeMake(attempt * 20 + 20, 600)];
		VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:d presentationTimeStamp:CMTimeMake(attempt * 20 + 10, 600)];
		VTLowLatencyFrameInterpolationParameters *p =
			[[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fs previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
		err = nil;
		BOOL pok = p && [proc processWithParameters:p error:&err];
		printf("  attempt %d (t+%.1fs): %s %s\n", attempt, attempt * 1.0, pok ? "OK" : "FAIL", pok ? "" : (err ? [[err localizedDescription] UTF8String] : "params nil"));
		CVPixelBufferRelease(d);
		if(pok)
			break;
		sleep(1);
	}
	[proc endSession];
	CVPixelBufferRelease(a);
	CVPixelBufferRelease(b);
}

int main(void)
{
	@autoreleasepool
	{
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("Metal default device: %s\n", dev ? [[dev name] UTF8String] : "NONE (no GPU access from this process)");
		printf("bundle id: %s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "(none)");
		printf("sandboxed env: APP_SANDBOX_CONTAINER_ID=%s\n", getenv("APP_SANDBOX_CONTAINER_ID") ?: "(unset)");
		printf("FrameRateConversion (macOS 15.4 API) isSupported: %d\n", (int)[VTFrameRateConversionConfiguration isSupported]);
		try_size(1280, 720);
		try_size(1920, 1080);
	}
	return 0;
}
