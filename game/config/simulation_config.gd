class_name SimulationConfig
extends Resource
enum SpatialBackend { AUTO, DENSE, SPARSE }
@export var spatial_backend: SpatialBackend = SpatialBackend.AUTO
enum MotionBackend { CPU, GPU }
@export var motion_backend: MotionBackend = MotionBackend.CPU
## Diagnostic A/B switch: both uploads feed the same numerical shader.
@export var gpu_bulk_upload: bool = true
## Owned by a dedicated executor; its Nodes never enter the active SceneTree.
@export var detached_ai: bool = false
## Independent executor service allowance per fixed step, including coordination.
## This is distinct from the legacy ai_budget_usec per render frame.
@export var worker_ai_budget_usec: int = 6000
## Durations ending in _ticks use the single fixed simulation clock.
@export var instrument_enabled: bool = false
@export var incremental_render_sort: bool = true
## Rendering experiment; the scene enables it, logic fixtures remain CPU-only.
@export var gpu_presentation: bool = false
# Keep exact target memories; represent passive flock knowledge as a local sample.
@export var compact_flock_knowledge: bool = true
# Candidate sharing remains an experiment; local crowd steering is the measured
# default. Either switch can be disabled independently for same-kernel comparisons.
@export var shared_cell_candidates: bool = false
@export var crowd_motion_enabled: bool = true
@export var crowd_prefix_counts: bool = true
@export var crowd_cell_size: float = 32.0
@export var crowd_enter_count: int = 24
@export var crowd_exit_count: int = 16
@export var fixed_dt: float = 1.0 / 60.0
@export var world_size: Vector2 = Vector2(1600.0, 1000.0)
@export var cell_size: float = 80.0
@export var perception_radius: float = 180.0
@export var neighbor_radius: float = 38.0
@export var separation_strength: float = 85.0
@export var acceleration: float = 240.0
@export var memory_ticks: int = 120
@export var safe_ticks: int = 90
@export var dog_leash_radius: float = 260.0
@export var lease_ticks: int = 90
@export var intent_ticks: int = 90
@export var ai_budget_usec: int = 2000
@export var perception_jobs: int = 512
@export var decision_jobs: int = 256
@export var attack_range: float = 16.0
@export var attack_windup_ticks: int = 12
@export var attack_window_ticks: int = 10
@export var attack_cooldown_ticks: int = 60
@export var feed_ticks: int = 120
@export var grazing_rate: float = 0.12
@export var hunger_rate: float = 0.015
@export var grass_recovery_rate: float = 0.035
@export var max_catchup_steps: int = 4
@export var spawn_per_tick: int = 64

# Steering weights and interaction distances are explicit tuning parameters.
@export var arrival_radius: float = 40.0
@export var alignment_weight: float = 0.2
@export var cohesion_weight: float = 0.18
@export var facing_min_speed: float = 2.0
@export var capture_nutrition: float = 0.8

@export var agent_radius: float = 13.0
@export var resource_cell_size: float = 80.0
# Food units: one fully grown standard 80 x 80 patch stores grass_capacity.
@export var initial_grass_coverage: float = 0.675
@export var grass_capacity: float = 1.0
@export var sheep_metabolism: float = 0.015
@export var sheep_stomach_capacity: float = 1.0
@export var forage_cell_radius: int = 1

## ECO-001: occupied blocks reduce storage, but measured slower up to 6400x4000.
## AUTO retains dense arrays; sparse remains an explicit memory/performance experiment.
func use_sparse_spatial() -> bool:
	if spatial_backend != SpatialBackend.AUTO:
		return spatial_backend == SpatialBackend.SPARSE
	return false
