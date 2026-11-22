# Frame generation module (macOS only).
#
# robzfg                static library: Apple's low-latency frame interpolation (VideoToolbox,
#                       macOS 26+) and repeated-frame detection
# framegen-engine-test  checks the engine on synthetic video with known motion
#
# Adapted from the robzfg module of Robz Play (kutsalkiremitci/robz-play); the RIFE / ncnn
# engine of the original is not part of this fork.

enable_language(OBJCXX)

add_library(robzfg STATIC
	include/robzfg/frame.h
	include/robzfg/timing.h
	include/robzfg/dedup.h
	include/robzfg/apple_interpolator.h
	src/dedup.cpp
	src/apple_interpolator.mm)
target_compile_features(robzfg PUBLIC cxx_std_17)
target_include_directories(robzfg PUBLIC include)
# The engine checks at run time that the system has the feature (AppleInterpolator::supported),
# so the calls into macOS 26 API need no guard of their own; the symbols are weak-linked.
set_source_files_properties(src/apple_interpolator.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc -Wno-unguarded-availability-new")
target_compile_definitions(robzfg PUBLIC ROBZFG_HAVE_APPLE=1)
target_link_libraries(robzfg PUBLIC "-framework VideoToolbox" "-framework CoreVideo" "-framework CoreMedia" "-framework Foundation")

if(CHIAKI_ENABLE_TESTS)
	add_executable(framegen-engine-test test/apple_interpolator_test.cpp test/synthetic_scene.h)
	target_link_libraries(framegen-engine-test PRIVATE robzfg)
	add_test(NAME framegen-engine COMMAND framegen-engine-test)
endif()
