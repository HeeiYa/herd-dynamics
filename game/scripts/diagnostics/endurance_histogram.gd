class_name EnduranceHistogram
extends RefCounted
## Fixed storage. Percentiles name their bucket interval, never false precision.
var bucket_width: float
var upper_bound: float
var unit: String
var count: int = 0
var overflow: int = 0
var invalid: int = 0
var total: float = 0.0
var minimum: float = INF
var maximum: float = -INF
var _buckets := PackedInt64Array()

func _init(width: float = 0.1, limit: float = 2000.0, value_unit: String = "ms") -> void:
	assert(width > 0.0 and limit > 0.0)
	bucket_width = width
	upper_bound = limit
	unit = value_unit
	_buckets.resize(ceili(limit / width) + 1)

func add(sample: float) -> void:
	if not is_finite(sample) or sample < 0.0:
		invalid += 1
		return
	count += 1
	total += sample
	minimum = minf(minimum, sample)
	maximum = maxf(maximum, sample)
	if sample > upper_bound:
		overflow += 1
		return
	var index: int = mini(_buckets.size() - 1, floori(sample / bucket_width))
	_buckets[index] += 1

func percentile(fraction: float) -> Dictionary:
	assert(fraction > 0.0 and fraction <= 1.0)
	if count == 0:
		return {"lower": null, "upper": null, "overflow": false}
	var rank: int = maxi(1, ceili(fraction * count))
	var seen: int = 0
	for index: int in _buckets.size():
		seen += _buckets[index]
		if seen >= rank:
			return {"lower": index * bucket_width,
				"upper": minf(upper_bound, (index + 1) * bucket_width), "overflow": false}
	return {"lower": upper_bound, "upper": null, "overflow": true}

func summary(include_buckets: bool = false) -> Dictionary:
	var result: Dictionary = {"unit": unit, "count": count, "sum": total,
		"minimum": minimum if count > 0 else null, "maximum": maximum if count > 0 else null,
		"overflow": overflow, "invalid": invalid, "bucket_width": bucket_width,
		"upper_bound": upper_bound, "bucket_count": _buckets.size(),
		"p50": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99)}
	if include_buckets:
		result["buckets"] = Array(_buckets)
	return result
