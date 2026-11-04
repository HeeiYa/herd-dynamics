class_name ProductionBehaviorProtocol
extends RefCounted
## Typed lifecycle for explicitly selected, worker-owned diagnostic scenarios.
## Ordinary simulation never constructs one. Reports contain copied primitives.
var finished: bool = false
var observer_usec: int = 0
var observed_steps: int = 0

func setup(_world: SimulationWorld, _sheep_count: int, _seed_value: int) -> void:
	assert(false, "A concrete behavior protocol must implement setup")

func before_step(_world: SimulationWorld) -> void:
	pass

func after_step(_world: SimulationWorld) -> void:
	assert(false, "A concrete behavior protocol must implement after_step")

func finish_report() -> Dictionary:
	assert(false, "A concrete behavior protocol must implement finish_report")
	return {}

func report_header(world: SimulationWorld, protocol: String, seed_value: int, sheep_count: int, started_usec: int) -> Dictionary:
	return {"protocol": protocol, "seed": seed_value, "requested_sheep": sheep_count,
		"world_size": [world.config.world_size.x, world.config.world_size.y],
		"end_tick": world.tick, "fixed_dt": world.config.fixed_dt,
		"ai_budget_usec": world.config.ai_budget_usec, "motion_backend": world.motion.backend_status,
		"detached_ai": world.config.detached_ai,
		"wall_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"observer_usec": observer_usec, "observed_steps": observed_steps,
		"clock_semantics": "Inputs observed post-stage0/pre-AI at n; owned decisions observed after the step; real displacement completes at n+1. Wall timestamps are observer detection times. Fixed seed does not make wall-budget scheduling deterministic.",
		"instrumentation": "Worker-owned read-only observations and declared external fixture interventions are timed in observer_usec. Observer cost is inside wall time and can alter scheduling. This is behavior evidence, not an unprobed capacity or latency baseline.",
		"acceptance": "Counts retain all declared eligible lives, nonresponders and terminal outcomes. Different protocol geometries and opportunity definitions cannot be compared as a common success rate."}
