#[compute]
#version 450

// S(n) is immutable for this dispatch. Dense links never survive a motion phase.
// Small indices/counts are exactly representable floats; identity validation and
// lifetime-dependent fallback directions remain on the CPU before submission.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
struct Actor {
    vec4 position_velocity;
    vec4 destination_speed_radius;
    vec4 facing_fallback;
    vec4 alive_held_species_mode;
    vec4 next_dense_slot_retreat;
};
struct Cell {
    vec4 position_radius_count;
    vec4 sheep_position_velocity;
    vec4 head_sheep_count;
};
struct Result {
    vec4 position_velocity;
    vec4 facing_displacement_moving;
    vec4 candidates_neighbors_contributions_cells;
};
layout(set = 0, binding = 0, std430) readonly buffer Actors { Actor actors[]; };
layout(set = 0, binding = 1, std430) readonly buffer Cells { Cell cells[]; };
layout(set = 0, binding = 2, std430) writeonly buffer Results { Result results[]; };
layout(set = 0, binding = 5, std430) readonly buffer BlockLookup { int block_lookup[]; };
layout(push_constant, std430) uniform Parameters {
    vec4 world_dt_count;
    vec4 grid_size_radius;
    vec4 acceleration_arrival_separation_facing;
    vec4 alignment_cohesion;
    vec4 sparse_cells_blocks_mask;
} parameters;

const int SHEEP = 0;
const int STOP = 0;
const int MOVE = 1;
const int FLEE = 2;
const int GRAZE = 3;
const int ATTACK = 4;
const float EPSILON = 0.00001;

// A one-ulp centroid error is amplified when subtracting a nearly coincident
// body position. Correct the division residual without requiring shader float64.
vec2 corrected_mean(vec2 sum, float count) {
    precise vec2 quotient = sum / count;
    precise vec2 residual = fma(-quotient, vec2(count), sum);
    precise vec2 corrected = quotient + residual / count;
    return corrected;
}

vec2 limit_length(vec2 value, float maximum) {
    float magnitude = length(value);
    return magnitude > maximum && magnitude > 0.0 ? value * (maximum / magnitude) : value;
}

// Match the CPU double subtraction at a float32 position exactly on the rounded
// boundary. Error-free TwoDiff keeps the residual instead of moving the wall by
// one ulp. Keep this predicate identical in gpu_motion_pack.glsl.
bool at_upper_soft_wall(float position, float world_extent, float radius) {
    precise float distance = radius * 2.0;
    precise float upper = world_extent - distance;
    precise float virtual_distance = world_extent - upper;
    precise float residual = (world_extent - (upper + virtual_distance)) + (virtual_distance - distance);
    return position > upper || (position == upper && residual <= 0.0);
}

vec2 remove_outward(vec2 pressure, vec2 position, float radius) {
    if ((position.x <= radius * 2.0 && pressure.x < 0.0) || (at_upper_soft_wall(position.x, parameters.world_dt_count.x, radius) && pressure.x > 0.0)) pressure.x = 0.0;
    if ((position.y <= radius * 2.0 && pressure.y < 0.0) || (at_upper_soft_wall(position.y, parameters.world_dt_count.y, radius) && pressure.y > 0.0)) pressure.y = 0.0;
    return pressure;
}

vec2 pair_direction(int own_slot, int other_slot) {
    // Reduce before multiplying to reproduce the CPU integer hash without
    // requiring shader int64. Preserve full slot order before reduction.
    int angle_degrees = ((min(own_slot, other_slot) % 360) * 293 + (max(own_slot, other_slot) % 360) * 23) % 360;
    float angle = float(angle_degrees) * 3.141592653589793 / 180.0;
    return vec2(cos(angle), sin(angle));
}

// SpatialCellMap uses occupied 4x4 blocks. Integer coordinate keys are not
// actor identities. Missing blocks are empty; no neighbor list is truncated.
int cell_slot(ivec2 coordinate, int columns) {
    if (parameters.sparse_cells_blocks_mask.z == 0.0) return coordinate.y * columns + coordinate.x;
    const int BLOCK_WIDTH = 4;
    int key = (coordinate.y / BLOCK_WIDTH) * int(parameters.sparse_cells_blocks_mask.y) + coordinate.x / BLOCK_WIDTH;
    uint mask = uint(parameters.sparse_cells_blocks_mask.w);
    uint bucket = (uint(key) * 73856093u) & mask;
    for (uint probe = 0u; probe <= mask; ++probe) {
        int stored_key = block_lookup[bucket * 2u];
        if (stored_key < 0) return -1;
        if (stored_key == key) {
            int block = block_lookup[bucket * 2u + 1u];
            return block * 16 + (coordinate.y % BLOCK_WIDTH) * BLOCK_WIDTH + coordinate.x % BLOCK_WIDTH;
        }
        bucket = (bucket + 1u) & mask;
    }
    return -1;
}

vec2 steering(uint index, out vec4 counters) {
    Actor actor = actors[index];
    vec2 position = actor.position_velocity.xy;
    float body_radius = actor.destination_speed_radius.w;
    float search_radius = parameters.grid_size_radius.w;
    ivec2 dimensions = ivec2(parameters.grid_size_radius.xy);
    float cell_size = parameters.grid_size_radius.z;
    ivec2 low = clamp(ivec2(floor((position - vec2(search_radius)) / cell_size)), ivec2(0), dimensions - 1);
    ivec2 high = clamp(ivec2(floor((position + vec2(search_radius)) / cell_size)), ivec2(0), dimensions - 1);
    ivec2 own_cell = clamp(ivec2(floor(position / cell_size)), ivec2(0), dimensions - 1);
    bool dense_sample = actor.next_dense_slot_retreat.y != 0.0;
    bool sheep = int(actor.alive_held_species_mode.z) == SHEEP;
    precise vec2 separation = vec2(0.0);
    precise vec2 flock_position = vec2(0.0);
    precise vec2 flock_velocity = vec2(0.0);
    float flock_count = 0.0;
    counters = vec4(0.0);
    for (int y = low.y; y <= high.y; ++y) {
        for (int x = low.x; x <= high.x; ++x) {
            int slot = cell_slot(ivec2(x, y), dimensions.x);
            counters.w += 1.0;
            if (slot < 0) continue;
            Cell cell = cells[slot];
            if (dense_sample) {
                float count = cell.position_radius_count.w;
                if (count == 0.0) continue;
                precise vec2 position_sum = cell.position_radius_count.xy;
                float radius_sum = cell.position_radius_count.z;
                float sheep_count = cell.head_sheep_count.y;
                vec4 sheep_sums = cell.sheep_position_velocity;
                if (all(equal(own_cell, ivec2(x, y)))) {
                    count -= 1.0;
                    position_sum -= position;
                    radius_sum -= body_radius;
                    if (sheep) {
                        sheep_count -= 1.0;
                        sheep_sums -= actor.position_velocity;
                    }
                }
                if (count == 0.0) continue;
                precise vec2 offset = position - corrected_mean(position_sum, count);
                if (dot(offset, offset) > search_radius * search_radius) continue;
                counters.z += count;
                float distance = length(offset);
                vec2 direction = distance <= 0.0001 ? actor.facing_fallback.zw : offset / distance;
                float spacing = body_radius + radius_sum / count;
                float proximity = clamp(1.0 - distance / max(spacing * 1.5, 0.0001), 0.0, 1.0);
                separation += direction * proximity * count;
                if (sheep && sheep_count > 0.0) {
                    flock_count += sheep_count;
                    flock_position += sheep_sums.xy;
                    flock_velocity += sheep_sums.zw;
                }
            } else {
                int neighbor = int(cell.head_sheep_count.x);
                while (neighbor >= 0) {
                    Actor other = actors[neighbor];
                    counters.x += 1.0;
                    precise vec2 offset = position - other.position_velocity.xy;
                    if (neighbor != int(index) && dot(offset, offset) <= search_radius * search_radius) {
                        counters.y += 1.0;
                        float distance = length(offset);
                        vec2 direction;
                        if (distance <= 0.0001) {
                            // Dense order does not encode slot order after swap deletion.
                            int own_slot = int(actor.next_dense_slot_retreat.z);
                            int other_slot = int(other.next_dense_slot_retreat.z);
                            direction = pair_direction(own_slot, other_slot);
                            if (own_slot >= other_slot) direction = -direction;
                        } else {
                            direction = offset / distance;
                        }
                        float spacing = body_radius + other.destination_speed_radius.w;
                        separation += direction * clamp(1.0 - distance / max(spacing * 1.5, 0.0001), 0.0, 1.0);
                        if (sheep && int(other.alive_held_species_mode.z) == SHEEP) {
                            flock_count += 1.0;
                            flock_position += other.position_velocity.xy;
                            flock_velocity += other.position_velocity.zw;
                        }
                    }
                    neighbor = int(other.next_dense_slot_retreat.x);
                }
            }
        }
    }
    if (dense_sample) {
        vec2 unbounded = separation;
        separation = remove_outward(separation, position, body_radius);
        if (all(lessThan(abs(separation), vec2(EPSILON))) && !all(lessThan(abs(unbounded), vec2(EPSILON)))) separation = actor.facing_fallback.zw;
    }
    separation = limit_length(separation, 1.0) * parameters.acceleration_arrival_separation_facing.z;
    if (flock_count == 0.0 || int(actor.alive_held_species_mode.w) != MOVE) return separation;
    return separation + (corrected_mean(flock_position, flock_count) - position) * parameters.alignment_cohesion.y
        + (corrected_mean(flock_velocity, flock_count) - actor.position_velocity.zw) * parameters.alignment_cohesion.x;
}

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= uint(parameters.world_dt_count.w)) return;
    Actor actor = actors[index];
    vec2 position = actor.position_velocity.xy;
    vec2 velocity = actor.position_velocity.zw;
    vec2 facing = actor.facing_fallback.xy;
    vec4 counters = vec4(0.0);
    if (actor.alive_held_species_mode.x == 0.0 || actor.alive_held_species_mode.y != 0.0) {
        results[index] = Result(vec4(position, vec2(0.0)), vec4(facing, 0.0, 0.0), counters);
        return;
    }
    int mode = int(actor.alive_held_species_mode.w);
    bool has_intent = mode >= 0;
    bool preserve_advance = mode == FLEE || mode == ATTACK;
    float speed = has_intent ? max(actor.destination_speed_radius.z, 0.0) : 0.0;
    float radius = actor.destination_speed_radius.w;
    vec2 guidance = vec2(0.0);
    if (has_intent && mode != STOP && mode != GRAZE) {
        precise vec2 offset = actor.destination_speed_radius.xy - position;
        float distance = length(offset);
        float arrival = preserve_advance ? radius : parameters.acceleration_arrival_separation_facing.y;
        if (distance > 0.0001) guidance = offset / distance * speed * clamp(distance / max(arrival, 0.0001), 0.0, 1.0);
    }
    vec2 desired = guidance;
    if (has_intent) {
        vec2 local = mode == STOP ? vec2(0.0) : steering(index, counters);
        if (preserve_advance && !all(lessThan(abs(guidance), vec2(EPSILON)))) {
            vec2 forward = normalize(guidance);
            local -= forward * min(dot(local, forward), 0.0);
        }
        desired += local;
        if (speed == 0.0 && mode == GRAZE) speed = parameters.acceleration_arrival_separation_facing.z;
    }
    precise vec2 difference = desired - velocity;
    float distance = length(difference);
    float acceleration = parameters.acceleration_arrival_separation_facing.x * parameters.world_dt_count.z;
    velocity = distance <= acceleration || distance < EPSILON ? desired : velocity + difference / distance * acceleration;
    velocity = limit_length(velocity, speed);
    precise vec2 next_position = position + velocity * parameters.world_dt_count.z;
    vec2 bounded = clamp(next_position, vec2(radius), parameters.world_dt_count.xy - vec2(radius));
    if (bounded.x != next_position.x) velocity.x = 0.0;
    if (bounded.y != next_position.y) velocity.y = 0.0;
    float facing_speed = parameters.acceleration_arrival_separation_facing.w;
    if (dot(velocity, velocity) >= facing_speed * facing_speed) {
        facing = normalize(velocity);
        if (has_intent && actor.next_dense_slot_retreat.w != 0.0 && !all(lessThan(abs(guidance), vec2(EPSILON)))) facing = -normalize(guidance);
    }
    float displacement = length(bounded - position);
    results[index] = Result(vec4(bounded, velocity), vec4(facing, displacement, displacement > 0.0001 ? 1.0 : 0.0), counters);
}
