class_name Probes
extends RefCounted
## Bounded diagnostics; never owns simulation state or consumes random numbers.
enum Tag { BEGIN_STEP, ENQUEUE, QUERY, REFRESH, PUBLISH, DECISION, PERCEPTION_JOB, GRASS, BUILD, SORT, COORDINATION, DELIVERY, REFRESH_DIRECT, REFRESH_SHARED, MERGE, OBSERVE, PRUNE }
enum Counter { PERCEPTION_SERVED, DECISION_SERVED, URGENT_SERVED, PERCEPTION_STALE, DECISION_STALE, URGENT_STALE, BUDGET_EXHAUSTED }
enum Task { WAITING, FEED, FLEE, GRAZE, GUARD, HUNT, INTERCEPT, REGROUP, ATTACK, RETURN, SEARCH, SEARCH_MEMORY }
const LABELS := ["ai.begin_step", "ai.enqueue", "ai.perception.query", "ai.perception.refresh", "ai.perception.publish", "ai.decision.update", "ai.perception.job", "render.grass.update", "render.build", "render.sort", "ai.coordination", "ai.delivery", "ai.perception.refresh.direct", "ai.perception.refresh.shared", "ai.delivery.merge", "ai.perception.observe", "ai.perception.prune"]
const TASKS := ["Waiting for first perception", "feed_capture", "flee_threat", "graze_grass", "guard_flock", "hunt_prey", "intercept_wolf", "regroup_flock", "request_attack", "return_to_flock", "search_area", "search_memory"]
const CAPACITY: int = 4096
const WIDTH: int = 8
var enabled: bool = false
static var labels := PackedStringArray(LABELS)
static var task_names := PackedStringArray(TASKS)
var sums := PackedInt64Array()
var counts := PackedInt64Array()
var maxima := PackedInt64Array()
var step_sums := PackedInt64Array()
var job_sums := PackedInt64Array()
var job_counts := PackedInt64Array()
var job_maxima := PackedInt64Array()
var histogram := PackedInt64Array()
var ring := PackedInt64Array()
var queue_ring := PackedInt64Array()
var queue_written: int = 0
var written: int = 0
var tick: int = 0
# perception/decision/urgent served, stale skips, budget exhaustions.
var counters := PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
var step_counters := PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
var queues := PackedInt64Array([0, 0, 0, 0, 0, 0])

func _init(active: bool = false) -> void:
	enabled = active
	sums.resize(Tag.size())
	counts.resize(Tag.size())
	maxima.resize(Tag.size())
	step_sums.resize(Tag.size())
	job_sums.resize(Tag.size() * 3)
	job_counts.resize(Tag.size() * 3)
	job_maxima.resize(Tag.size() * 3)
	histogram.resize(Tag.size() * 3 * 64)
	ring.resize(CAPACITY * WIDTH)
	queue_ring.resize(CAPACITY * 14)

func reset_window() -> void:
	sums.fill(0)
	counts.fill(0)
	maxima.fill(0)
	job_sums.fill(0)
	job_counts.fill(0)
	job_maxima.fill(0)
	histogram.fill(0)
	counters.fill(0)
	written = 0
	queue_written = 0

func begin_step(at_tick: int) -> void:
	tick = at_tick
	step_sums.fill(0)
	step_counters.fill(0)

func record(label: Tag, elapsed_us: int) -> void:
	sums[label] += elapsed_us
	counts[label] += 1
	maxima[label] = maxi(maxima[label], elapsed_us)
	step_sums[label] += elapsed_us

func count_job(index: int) -> void:
	counters[index] += 1
	step_counters[index] += 1

func job(label: Tag, species: int, elapsed_us: int, candidates: int = 0, observations: int = 0, task: int = -1, elapsed_ticks: int = 0) -> void:
	var group: int = species * Tag.size() + label
	job_sums[group] += elapsed_us
	job_counts[group] += 1
	job_maxima[group] = maxi(job_maxima[group], elapsed_us)
	# Bucket 0 contains 0 us; k>0 contains [2^(k-1), 2^k) us.
	var bucket: int = 0
	var remaining: int = elapsed_us
	while remaining > 0 and bucket < 63:
		remaining >>= 1
		bucket += 1
	histogram[group * 64 + bucket] += 1
	var offset: int = (written % CAPACITY) * WIDTH
	ring[offset] = tick
	ring[offset + 1] = label
	ring[offset + 2] = species
	ring[offset + 3] = elapsed_us
	ring[offset + 4] = candidates
	ring[offset + 5] = observations
	ring[offset + 6] = task
	ring[offset + 7] = elapsed_ticks
	written += 1

func summary() -> Dictionary:
	var totals: Array[Dictionary] = []
	var jobs: Array[Dictionary] = []
	for label: int in Tag.size():
		totals.append({"label": labels[label], "sum_us": sums[label], "count": counts[label], "max_us": maxima[label]})
	for species: int in 3:
		for label: int in Tag.size():
			var group: int = species * Tag.size() + label
			if job_counts[group] == 0:
				continue
			jobs.append({"species": species, "label": labels[label], "sum_us": job_sums[group], "count": job_counts[group], "max_us": job_maxima[group], "histogram": Array(histogram.slice(group * 64, (group + 1) * 64))})
	var ranked: Array[Dictionary] = totals.duplicate()
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.sum_us > b.sum_us)
	return {"enabled": enabled, "labels": labels, "tasks": task_names, "totals": totals, "jobs": jobs, "top_5": ranked.slice(0, 5), "nested_labels_not_additive": true, "counters": Array(counters), "counter_columns": ["perception_served", "decision_served", "urgent_served", "perception_stale", "decision_stale", "urgent_stale", "budget_exhaustions"], "queue_ring_overwritten": maxi(0, queue_written - CAPACITY), "ring_overwritten": maxi(0, written - CAPACITY), "gpu_time": "not measured; requires external tools"}

func export_jobs(directory: String) -> void:
	var file: FileAccess = FileAccess.open(directory.path_join("jobs.csv"), FileAccess.WRITE)
	assert(file != null, "Cannot write job diagnostics")
	file.store_csv_line(PackedStringArray(["tick", "label", "species", "elapsed_us", "candidates", "observations", "task", "elapsed_ticks"]))
	for sequence: int in range(maxi(0, written - CAPACITY), written):
		var row := PackedStringArray()
		var offset: int = (sequence % CAPACITY) * WIDTH
		for field: int in WIDTH:
			row.append(str(ring[offset + field]))
		file.store_csv_line(row)
	file.close()

func step_columns() -> PackedStringArray:
	var result := PackedStringArray()
	for elapsed_us: int in step_sums:
		result.append(str(elapsed_us))
	for value: int in queues:
		result.append(str(value))
	for value: int in step_counters:
		result.append(str(value))
	return result

func column_names() -> PackedStringArray:
	var result: PackedStringArray = labels.duplicate()
	result.append_array(PackedStringArray(["perception_pending", "decision_pending", "urgent_pending", "perception_oldest_ticks", "decision_oldest_ticks", "urgent_oldest_ticks", "perception_served", "decision_served", "urgent_served", "perception_stale", "decision_stale", "urgent_stale", "budget_exhaustions"]))
	return result

func end_step() -> void:
	var offset: int = (queue_written % CAPACITY) * 14
	queue_ring[offset] = tick
	for index: int in 6:
		queue_ring[offset + 1 + index] = queues[index]
	for index: int in 7:
		queue_ring[offset + 7 + index] = step_counters[index]
	queue_written += 1

func export_queues(directory: String) -> void:
	var file: FileAccess = FileAccess.open(directory.path_join("queues.csv"), FileAccess.WRITE)
	assert(file != null)
	var header := PackedStringArray(["tick"])
	header.append_array(column_names().slice(Tag.size()))
	file.store_csv_line(header)
	for sequence: int in range(maxi(0, queue_written - CAPACITY), queue_written):
		var row := PackedStringArray()
		for field: int in 14:
			row.append(str(queue_ring[(sequence % CAPACITY) * 14 + field]))
		file.store_csv_line(row)
	file.close()
