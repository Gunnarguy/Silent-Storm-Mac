// Headless regression check. No NSApplication, window, pointer events or cursor APIs.
// clang++ -std=c++17 port/tools/test_mouse_motion.cpp -o /private/tmp/test_mouse_motion
#include "../platform/src/s2mousemotion.h"
#include <cassert>
#include <iostream>

static void checkPackets(int axis, double packet, int count)
{
	S2MouseMotion motion;
	long emitted = 0;
	for (int i = 0; i < count; ++i)
	{
		emitted += motion.add(axis, packet);
		assert(std::abs(emitted - packet * (i + 1)) <= 0.500001);
	}
	assert(std::abs(emitted + motion.remainder[axis] - packet * count) < 0.000001);
}

int main()
{
	// Slow mouse/trackpad motion, both directions and all three axes, must survive
	// packetization. Previously every small delta rounded to zero individually.
	for (int axis = 0; axis < 3; ++axis)
		for (double delta : {0.01, 0.2, 0.49, 0.75, 3.25, -0.01, -0.2, -0.49, -0.75, -3.25})
			checkPackets(axis, delta, 10000);
	S2MouseMotion motion;
	assert(motion.add(0, 0.4) == 0);
	assert(motion.add(1, -0.4) == 0);
	assert(motion.add(0, 0.4) == 1);
	assert(motion.add(1, -0.4) == -1);
	assert(motion.add(0, -0.8) == -1);
	assert(motion.add(1, 0.8) == 1);
	// A new drag/focus transition must not inherit fractional movement.
	motion.add(0, 0.4);
	motion.add(2, -0.4);
	motion.reset();
	assert(motion.add(0, 0.2) == 0);
	assert(motion.add(2, -0.2) == 0);
	std::cout << "PASS: fractional motion conserved across 300000 packets; axes, reversal and release reset verified\n";
}
