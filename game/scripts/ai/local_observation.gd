class_name LocalObservation
extends RefCounted
## A sighting is knowledge, never a view onto the target's live position arrays.
enum Source { DIRECT, SHARED }
var handle: AgentHandle
var species: int = SimTypes.Species.SHEEP
var position: Vector2 = Vector2.ZERO
var velocity: Vector2 = Vector2.ZERO
var observed_tick: int = 0
# Receiver-owned provenance: a newer shared report cannot erase its own scan.
var last_direct_tick: int = -1
var expires_tick: int = 0
var source: Source = Source.DIRECT

func predicted_position(tick: int, fixed_dt: float, settings: AISettings) -> Vector2:
	var seconds: float = minf(float(maxi(0, tick - observed_tick)) * fixed_dt, settings.prediction_seconds)
	return position + (velocity * seconds).limit_length(settings.max_prediction_distance)

func was_visible_at_scan(scan_tick: int, tick: int, memory_ticks: int) -> bool:
	return scan_tick >= 0 and last_direct_tick == scan_tick and tick < last_direct_tick + memory_ticks

func copy_sighting() -> LocalObservation:
	# Do not copy last_direct_tick: a peer's eyesight is not the receiver's eyesight.
	var copy := LocalObservation.new()
	copy.handle = handle
	copy.species = species
	copy.position = position
	copy.velocity = velocity
	copy.observed_tick = observed_tick
	copy.expires_tick = expires_tick
	copy.source = Source.SHARED
	return copy
