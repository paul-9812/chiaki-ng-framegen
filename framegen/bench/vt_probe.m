// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Probe: what does VTLowLatencyFrameInterpolation support on this Mac?
// Prints whether the processor is supported, and for a few picture sizes whether a
// configuration can be created, which pixel formats it takes and the buffer attributes it wants.
//
// build: clang -fobjc-arc -mmacosx-version-min=26.0 -O2 vt_probe.m -o vt_probe \
//          -framework Foundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework Metal
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>

static NSString *fourcc(uint32_t v)
{
	char c[5] = {(char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0};
	for(int i = 0; i < 4; i++)
		if(c[i] < 32 || c[i] > 126)
			return [NSString stringWithFormat:@"0x%08x", v];
	return [NSString stringWithFormat:@"'%s'", c];
}

int main(void)
{
	@autoreleasepool
	{
		if(@available(macOS 26.0, *))
		{
			Class cls = [VTLowLatencyFrameInterpolationConfiguration class];
			printf("isSupported: %d\n", (int)[VTLowLatencyFrameInterpolationConfiguration isSupported]);
			if([cls respondsToSelector:@selector(maximumDimensions)])
			{
				CMVideoDimensions d = [VTLowLatencyFrameInterpolationConfiguration maximumDimensions];
				printf("maximumDimensions: %d x %d\n", d.width, d.height);
			}
			else
				printf("maximumDimensions: (not implemented)\n");
			if([cls respondsToSelector:@selector(minimumDimensions)])
			{
				CMVideoDimensions d = [VTLowLatencyFrameInterpolationConfiguration minimumDimensions];
				printf("minimumDimensions: %d x %d\n", d.width, d.height);
			}
			else
				printf("minimumDimensions: (not implemented)\n");

			int sizes[][2] = {{960, 540}, {1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}};
			for(size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++)
			{
				int w = sizes[i][0], h = sizes[i][1];
				VTLowLatencyFrameInterpolationConfiguration *cfg =
					[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];
				printf("\n== %dx%d interp x1: %s\n", w, h, cfg ? "config OK" : "config NIL (unsupported)");
				if(!cfg)
					continue;
				NSMutableArray *names = [NSMutableArray array];
				for(NSNumber *n in cfg.frameSupportedPixelFormats)
					[names addObject:fourcc(n.unsignedIntValue)];
				printf("   pixel formats: %s\n", [[names componentsJoinedByString:@", "] UTF8String]);
				if(w == 1920)
				{
					printf("   source attrs: %s\n", [[cfg.sourcePixelBufferAttributes description] UTF8String]);
					printf("   dest attrs:   %s\n", [[cfg.destinationPixelBufferAttributes description] UTF8String]);
					if([cfg respondsToSelector:@selector(previousFrameCount)])
						printf("   previousFrameCount: %ld\n", (long)cfg.previousFrameCount);
					if([cfg respondsToSelector:@selector(nextFrameCount)])
						printf("   nextFrameCount: %ld\n", (long)cfg.nextFrameCount);
				}
			}
			// spatial 2x + temporal (540p -> 1080p, 1080p -> 4K)
			int ssizes[][2] = {{960, 540}, {1920, 1080}};
			for(size_t i = 0; i < 2; i++)
			{
				VTLowLatencyFrameInterpolationConfiguration *cfg =
					[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:ssizes[i][0] frameHeight:ssizes[i][1] spatialScaleFactor:2];
				printf("\n== %dx%d interp + 2x upscale: %s\n", ssizes[i][0], ssizes[i][1], cfg ? "config OK" : "config NIL (unsupported)");
			}
		}
		else
			printf("macOS < 26: API unavailable\n");
	}
	return 0;
}
