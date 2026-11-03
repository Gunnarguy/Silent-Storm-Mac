#pragma once
#include <cmath>

// AppKit delivers fractional motion. Quantize the running total rather than each
// packet, so slow drags retain their motion regardless of event frequency.
struct S2MouseMotion
{
	double remainder[3] = {};
	long add(int axis, double delta)
	{
		double total = remainder[axis] + delta;
		long whole = std::lround(total);
		remainder[axis] = total - whole;
		return whole;
	}
	void reset() { for (double &value : remainder) value = 0; }
};
