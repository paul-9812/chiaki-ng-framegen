// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Frame generation stage of the stream pipeline (macOS; taken from Robz Play, see framegen.cpp).
//
// Sits between the video decoder and the renderer. For a game that renders 30 fps
// inside a 60 fps stream it drops the repeated frames, synthesizes the missing
// in-between frames (Apple's frame interpolation) and hands everything to the renderer on a steady
// cadence: one generated frame per real one for 60 fps, three for 120 fps. Anything it
// cannot improve (content already at the target rate, unsupported pixel formats, a
// model that failed to load) passes through untouched.
//
// Two threads do the work. The worker recognises repeats and generates frames; the
// presenter hands frames on at the moment they are due. Keeping them apart is what lets
// several frames be generated in a row without the ones already finished going out late.

#ifndef ROBZPLAY_FRAMEGEN_H
#define ROBZPLAY_FRAMEGEN_H

#include <QObject>
#include <QString>
#include <QTimer>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <chiaki/ffmpegdecoder.h>

class FrameGenStage : public QObject
{
	Q_OBJECT
	// True while a stream is running with frame generation switched on.
	Q_PROPERTY(bool enabled READ enabled NOTIFY stateChanged)
	// Short human-readable state: "loading", "generating", "passing through (...)", an error ...
	Q_PROPERTY(QString status READ status NOTIFY stateChanged)
	// Frames per second of real (non-repeated) game frames arriving from the console.
	Q_PROPERTY(double sourceFps READ sourceFps NOTIFY statsChanged)
	// Frames per second handed to the renderer.
	Q_PROPERTY(double outputFps READ outputFps NOTIFY statsChanged)
	// Time to synthesize one frame, in milliseconds (recent average).
	Q_PROPERTY(double generateMs READ generateMs NOTIFY statsChanged)

public:
	struct Config
	{
		bool enabled = false;
		// Output rate to aim for: 60 or 120 frames per second.
		unsigned int target_fps = 60;
		unsigned int stream_fps = 60;
		// Picture size of the stream, when it is known before video arrives (0 = not known).
		// The engine then gets ready while the stream is still connecting; otherwise it does
		// so on the first frame, which holds video up for as long as that takes.
		int stream_width = 0;
		int stream_height = 0;
		// Passed on to the engine: 0 lets it decide whether the picture has to be split into
		// bands (see robzfg::AppleInterpolator::Config).
		int band_pixel_limit = 0;
	};

	// Called for every frame that should be shown; takes ownership of the frame. Runs on the
	// presenter thread, or on the thread calling submit() while the model is still loading.
	using PresentFn = std::function<void(ChiakiFfmpegFrame frame, int32_t frames_lost, qint64 delivery_us)>;

	explicit FrameGenStage(QObject *parent = nullptr);
	~FrameGenStage() override;

	void start(const Config &config, PresentFn present);
	void stop();

	// What a self-test found.
	struct SelfTestResult
	{
		QString status;
		int frames_in = 0;
		int frames_out = 0;
		double source_fps = 0.0;
		double output_fps = 0.0;
		double generate_ms = 0.0;
	};

	// Diagnostic: runs the stage on `frames` frames of synthetic 30 fps video (240 = 8 s)
	// inside the running application and prints the outcome to stderr. Started by launching
	// with CHIAKI_FRAMEGEN_SELFTEST=1; checks that the engine starts and generates frames on
	// this machine without needing a console.
	// `on_presented` (optional) is called for every frame the stage hands on; `on_finished`
	// (optional) gets the outcome once the stage has stopped again, on this object's thread.
	// Starting a stream, stopping or destroying the stage ends a self-test that is under way.
	void runSelfTest(const Config &config, std::function<void()> on_presented = {},
		std::function<void(const SelfTestResult &)> on_finished = {}, int frames = 240);

	// Hands a decoded frame to the stage (takes ownership). Safe to call from any one thread.
	void submit(ChiakiFfmpegFrame frame, int32_t frames_lost, qint64 delivery_us);

	bool enabled() const { return running.load() && config.enabled; }
	QString status() const;
	double sourceFps() const { return stat_source_fps.load(); }
	double outputFps() const { return stat_output_fps.load(); }
	double generateMs() const { return stat_generate_ms.load(); }

signals:
	void stateChanged();
	void statsChanged();

private:
	struct Item
	{
		ChiakiFfmpegFrame frame = {};
		int32_t frames_lost = 0;
		qint64 delivery_us = 0;
		uint64_t arrival_us = 0;
	};
	struct Scheduled
	{
		Item item;
		uint64_t due_us = 0;
	};
	struct Engine;

	// A thread's place to sleep until there is work or a deadline has come. On Windows it
	// waits on an event and a high-resolution timer: the default timer tick (15.6 ms) is as
	// long as the frame intervals this stage has to hit.
	struct Waiter
	{
		void open();
		void close();
		void signal();
		// Called with `lock` held; returns with it held.
		void wait(std::unique_lock<std::mutex> &lock, uint64_t timeout_us);

		std::condition_variable condition;
		void *event = nullptr;
		void *timer = nullptr;
	};

	void workerMain();
	void presenterMain();
	void process(Item &item);
	void schedule(Item &item, uint64_t due_us);
	void scheduleNow(Item &item);
	void flushSchedule();
	void setStatus(const std::string &text);
	void publishStats();

	Config config;
	PresentFn present;
	std::atomic<bool> running{false};
	// set once the model is loaded; until then (and if loading fails) frames bypass the worker
	std::atomic<bool> engine_ready{false};

	// decoded frames waiting for the worker
	std::thread worker;
	std::mutex queue_mutex;
	std::deque<Item> queue;
	Waiter work_waiter;
	bool stop_requested = false;

	// frames waiting for their turn on the output timeline, earliest first
	std::thread presenter;
	std::mutex schedule_mutex;
	std::deque<Scheduled> scheduled;
	Waiter present_waiter;
	bool presenter_stop = false;

	// worker-thread state
	std::unique_ptr<Engine> engine;
	// when the last real frame is (or was) due; the timeline the output cadence runs on
	bool timeline_valid = false;
	double timeline_real_due_us = 0.0;
	uint64_t last_due_us = 0;
	uint64_t last_unique_us = 0;
	// running average of the time between real frames, and how many frames to put in between
	double cadence_us = 0.0;
	unsigned int cadence_samples = 0;
	int intermediates = 0;
	int32_t carried_frames_lost = 0;
	std::vector<uint8_t> scratch_uv;
	std::vector<uint8_t> scratch_out_uv;
	uint64_t stats_window_start_us = 0;
	std::atomic<unsigned int> stats_unique{0};
	std::atomic<unsigned int> stats_presented{0};

	// self-test: a thread of its own plays the part of the stream
	void endSelfTest();
	std::thread selftest_feeder;
	std::atomic<bool> selftest_stop{false};
	std::atomic<int> selftest_fed{0};
	unsigned int selftest_run = 0;

	mutable std::mutex status_mutex;
	std::string status_text;
	std::atomic<bool> status_dirty{false};
	std::atomic<double> stat_source_fps{0.0};
	std::atomic<double> stat_output_fps{0.0};
	std::atomic<double> stat_generate_ms{0.0};
	QTimer poll_timer;
};

#endif // ROBZPLAY_FRAMEGEN_H
