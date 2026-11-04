class_name PublishedPose
extends RefCounted
## Immutable visual clock for one complete life. No texture or scene resources.
var handle: AgentHandle
var species: int
var behavior: int
var action: int
var direction: int
var previous_direction: int
var direction_tick: int
var started_tick: int
var phase_direction: int

static func sample(world: SimulationWorld, dense: int, previous: PublishedPose) -> PublishedPose:
	var handle: AgentHandle = world.store.handle_at(dense)
	var species: int = world.store.species[dense]
	var intent: MotionIntent = world.intents.get_intent(handle, maxi(0, world.tick - 1))
	var behavior: int = intent.behavior if intent != null else SimTypes.Behavior.IDLE
	var pressure: bool = intent != null and intent.mode == SimTypes.IntentMode.PRESSURE
	var action: int = AnimationCatalog.action_for(species, behavior, world.store.velocity_current[dense].length_squared() > 9.0, pressure)
	var continuing: bool = previous != null and previous.handle.same_life(handle)
	var direction: int = AnimationCatalog.direction_for(world.store.facing[dense], previous.direction if continuing else 0)
	if continuing and action == previous.action and direction == previous.direction and behavior == previous.behavior:
		return previous
	var pose := PublishedPose.new()
	pose.handle = handle
	pose.species = species
	pose.behavior = behavior
	pose.action = action
	pose.direction = direction
	pose.direction_tick = world.tick
	if not continuing:
		pose.previous_direction = direction
		pose.phase_direction = direction
		pose.started_tick = maxi(0, world.tick - 1)
	else:
		pose.previous_direction = previous.direction
		pose.started_tick = previous.started_tick if action == previous.action else maxi(0, world.tick - 1)
		pose.phase_direction = previous.phase_direction if action == previous.action else previous.direction
		if direction == previous.direction:
			pose.previous_direction = previous.previous_direction
			pose.direction_tick = previous.direction_tick
	return pose
