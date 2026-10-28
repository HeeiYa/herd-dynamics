class_name SimulationConfig
extends Resource
## Durations ending in _ticks use the single fixed simulation clock.
@export var instrument_enabled: bool = false
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
@export var grazing_distance: float = 24.0
@export var capture_nutrition: float = 0.8

@export var agent_radius: float = 13.0
@export var resource_cell_size: float = 80.0
