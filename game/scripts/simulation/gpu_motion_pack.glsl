#[compute]
#version 450

// Convert native packed CPU columns to the existing numerical kernel's records.
// This pass changes representation only; the barrier before motion publishes
// every actor and cell together. Offsets are 32-bit words, C is capacity/count.
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
layout(set = 0, binding = 0, std430) writeonly buffer Actors { Actor actors[]; };
layout(set = 0, binding = 1, std430) writeonly buffer Cells { Cell cells[]; };
layout(set = 0, binding = 3, std430) readonly buffer ActorColumns { float actor_words[]; };
layout(set = 0, binding = 4, std430) readonly buffer CellColumns { float cell_words[]; };
layout(push_constant, std430) uniform Parameters {
    vec4 world_dt_count;
    vec4 grid_size_radius;
    vec4 acceleration_arrival_separation_facing;
    vec4 alignment_cohesion;
} parameters;

vec2 actor_vector2(int offset) {
    return vec2(actor_words[offset], actor_words[offset + 1]);
}

vec4 actor_vector4(int offset) {
    return vec4(actor_vector2(offset), actor_vector2(offset + 2));
}

vec2 cell_vector2(int offset) {
    return vec2(cell_words[offset], cell_words[offset + 1]);
}

// Error-free TwoDiff reproduces the CPU's double comparison for float32 inputs.
// Keep this predicate identical in gpu_motion.glsl.
bool at_upper_soft_wall(float position, float world_extent, float radius) {
    precise float distance = radius * 2.0;
    precise float upper = world_extent - distance;
    precise float virtual_distance = world_extent - upper;
    precise float residual = (world_extent - (upper + virtual_distance)) + (virtual_distance - distance);
    return position > upper || (position == upper && residual <= 0.0);
}

void pack_actor(int index) {
    int capacity = int(parameters.alignment_cohesion.w);
    vec2 position = actor_vector2(index * 2);
    vec2 velocity = actor_vector2(capacity * 2 + index * 2);
    vec2 facing = actor_vector2(capacity * 4 + index * 2);
    float radius = actor_words[capacity * 6 + index];
    int species = floatBitsToInt(actor_words[capacity * 7 + index]);
    int slot = floatBitsToInt(actor_words[capacity * 8 + index]);
    int next_neighbor = floatBitsToInt(actor_words[capacity * 9 + index]);
    vec2 fallback = actor_vector2(capacity * 10 + index * 2);
    vec4 intent = actor_vector4(capacity * 12 + index * 4);
    vec4 flags = actor_vector4(capacity * 16 + index * 4);
    // The CPU keeps full generation/epoch precision. Wall reflection follows
    // the current position, so cached identity directions never freeze a wall.
    if (position.x <= radius * 2.0) fallback.x = abs(fallback.x);
    else if (at_upper_soft_wall(position.x, parameters.world_dt_count.x, radius)) fallback.x = -abs(fallback.x);
    if (position.y <= radius * 2.0) fallback.y = abs(fallback.y);
    else if (at_upper_soft_wall(position.y, parameters.world_dt_count.y, radius)) fallback.y = -abs(fallback.y);
    bool alive = flags.x != 0.0;
    bool held = flags.x == 1.0;
    actors[index] = Actor(vec4(position, velocity), vec4(intent.xyz, radius), vec4(facing, fallback),
        vec4(float(alive), float(held), float(species), intent.w),
        vec4(float(next_neighbor), flags.y, float(slot), flags.z));
}

void pack_cell(int index, int count) {
    vec2 position_sum = cell_vector2(index * 2);
    float radius_sum = cell_words[count * 2 + index];
    int body_count = floatBitsToInt(cell_words[count * 3 + index]);
    vec2 sheep_position = cell_vector2(count * 4 + index * 2);
    vec2 sheep_velocity = cell_vector2(count * 6 + index * 2);
    int head = floatBitsToInt(cell_words[count * 8 + index]);
    int sheep_count = floatBitsToInt(cell_words[count * 9 + index]);
    cells[index] = Cell(vec4(position_sum, radius_sum, float(body_count)),
        vec4(sheep_position, sheep_velocity), vec4(float(head), float(sheep_count), 0.0, 0.0));
}

void main() {
    int index = int(gl_GlobalInvocationID.x);
    int cell_count = int(parameters.grid_size_radius.x) * int(parameters.grid_size_radius.y);
    if (index < int(parameters.world_dt_count.w)) pack_actor(index);
    if (index < cell_count) pack_cell(index, cell_count);
}
