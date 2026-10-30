class_name GroundLayer
extends Node2D
## Warm meadow ground. Grass amount drives one tiny color image, one pixel per
## resource cell, drawn with linear filtering so neighboring cells blend
## instead of forming hard blocks. Only a quantized level change rewrites a
## pixel. Decorations are drawn once from their own seed: they never consume
## the simulation stream and imply no collision or occlusion.
##
## The thousands of decoration strokes are baked into one offscreen texture
## (rendered once per seed) because drawing them live costs hundreds of
## unbatchable draw calls every frame.

const LEVELS: int = 8
const DRY := Color("c7b27a")
const MID := Color("a3b264")
const LUSH := Color("6f9a48")
const OUTSIDE := Color("3e4a34")
const EDGE := Color("5d6b45")
# Baked at twice world resolution so tufts stay crisp when zoomed in.
const DECORATION_SCALE: float = 2.0

var _resources: ResourceGrid
var _world_size: Vector2
var _image: Image
var _texture: ImageTexture
var _levels: PackedInt32Array = PackedInt32Array()
var _detail: Texture2D
var _decor: Decorations
var _decor_viewport: SubViewport

## Static decorative marks, retained in one canvas item.
class Decorations extends Node2D:
	var world_size: Vector2
	var decoration_seed: int = 0

	func _draw() -> void:
		var random := RandomNumberGenerator.new()
		random.seed = hash(Vector2i(decoration_seed, 0xdec0))
		var area: float = world_size.x * world_size.y
		# Large soft tone patches give the meadow uneven density.
		for index: int in roundi(area / 32000.0):
			var radius: float = random.randf_range(40.0, 110.0)
			# Patches stay inside the pasture so the boundary remains crisp.
			var center := Vector2(random.randf_range(radius, world_size.x - radius), random.randf_range(radius, world_size.y - radius))
			var tone: Color = Color("4f7a35") if random.randf() < 0.55 else Color("d8c48c")
			tone.a = random.randf_range(0.04, 0.09)
			draw_set_transform(center, random.randf_range(0.0, PI), Vector2(1.0, random.randf_range(0.5, 0.9)))
			draw_circle(Vector2.ZERO, radius, tone, true, -1.0, true)
		draw_set_transform(Vector2.ZERO)
		# Bare soil spots: flat, low-contrast ellipses.
		for index: int in roundi(area / 60000.0):
			var center := Vector2(random.randf() * world_size.x, random.randf() * world_size.y)
			draw_set_transform(center, random.randf_range(0.0, PI), Vector2(1.0, 0.55))
			draw_circle(Vector2.ZERO, random.randf_range(7.0, 16.0), Color(0.62, 0.5, 0.33, 0.28), true, -1.0, true)
		draw_set_transform(Vector2.ZERO)
		# Grass tufts: three short hand-drawn strokes.
		for index: int in roundi(area / 1700.0):
			var base := Vector2(random.randf() * world_size.x, random.randf() * world_size.y)
			var shade: Color = Color("3f6a2c") if random.randf() < 0.7 else Color("8aa357")
			shade.a = random.randf_range(0.35, 0.6)
			var height: float = random.randf_range(3.0, 6.5)
			draw_line(base, base + Vector2(-2.0, -height * 0.8), shade, 1.0)
			draw_line(base, base + Vector2(0.4, -height), shade, 1.0)
			draw_line(base, base + Vector2(2.2, -height * 0.7), shade, 1.0)
		# Sparse flowers in small clusters.
		var petals: Array[Color] = [Color("f6efd8"), Color("f2d36b"), Color("e8a6a0"), Color("c9b8e6")]
		for cluster: int in roundi(area / 40000.0):
			var center := Vector2(random.randf() * world_size.x, random.randf() * world_size.y)
			var petal: Color = petals[random.randi_range(0, petals.size() - 1)]
			for flower: int in random.randi_range(2, 6):
				var point: Vector2 = center + Vector2(random.randf_range(-14.0, 14.0), random.randf_range(-8.0, 8.0))
				draw_circle(point, 1.6, petal, true, -1.0, true)
				draw_circle(point, 0.6, Color("c8873a"), true, -1.0, true)

func configure(resources: ResourceGrid, world_size: Vector2, detail: Texture2D) -> void:
	_resources = resources
	_world_size = world_size
	_detail = detail
	_levels.resize(resources.cell_count)
	_levels.fill(-1)
	_image = Image.create_empty(resources.columns, resources.rows, false, Image.FORMAT_RGB8)
	_image.fill(MID)
	_texture = ImageTexture.create_from_image(_image)
	_decor = Decorations.new()
	_decor.world_size = world_size
	_decor.scale = Vector2.ONE * DECORATION_SCALE
	_decor_viewport = SubViewport.new()
	_decor_viewport.size = Vector2i((world_size * DECORATION_SCALE).ceil())
	_decor_viewport.transparent_bg = true
	_decor_viewport.disable_3d = true
	_decor_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_decor_viewport.add_child(_decor)
	add_child(_decor_viewport)
	# Linear filtering blends neighboring resource cells into soft gradients.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED

func set_decoration_seed(value: int) -> void:
	if _decor.decoration_seed == value:
		return
	_decor.decoration_seed = value
	_decor.queue_redraw()
	_decor_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func clear_levels() -> void:
	_levels.fill(-1)

func update_at(display_tick: float) -> void:
	var dirty: bool = false
	var earlier: int = floori(display_tick)
	var later: int = ceili(display_tick)
	for cell: int in _resources.cell_count:
		var amount: float = lerpf(_resources.get_effective_amount(cell, earlier), _resources.get_effective_amount(cell, later), display_tick - earlier)
		var level: int = clampi(floori(amount * LEVELS), 0, LEVELS - 1)
		if _levels[cell] == level:
			continue
		_levels[cell] = level
		_image.set_pixel(cell % _resources.columns, cell / _resources.columns, _level_color(level))
		dirty = true
	if dirty:
		_texture.update(_image)

static func _level_color(level: int) -> Color:
	var amount: float = (float(level) + 0.5) / LEVELS
	if amount < 0.4:
		return DRY.lerp(MID, amount / 0.4)
	return MID.lerp(LUSH, (amount - 0.4) / 0.6)

func _draw() -> void:
	var margin: float = 600.0
	draw_rect(Rect2(-Vector2.ONE * margin, _world_size + Vector2.ONE * margin * 2.0), OUTSIDE)
	# Resource cells may extend past the world edge; scale to the full grid.
	var grid_size := Vector2(_resources.columns, _resources.rows) * _resources.cell_size
	draw_texture_rect(_texture, Rect2(Vector2.ZERO, grid_size), false)
	if _detail != null:
		draw_texture_rect(_detail, Rect2(Vector2.ZERO, _world_size), true, Color(1, 1, 1, 0.16))
	draw_texture_rect(_decor_viewport.get_texture(), Rect2(Vector2.ZERO, _world_size), false)
	# Cover the overhang beyond the world, then mark the real pasture boundary.
	draw_rect(Rect2(Vector2(_world_size.x, 0), Vector2(grid_size.x - _world_size.x + margin, grid_size.y + margin)), OUTSIDE)
	draw_rect(Rect2(Vector2(0, _world_size.y), Vector2(grid_size.x + margin, grid_size.y - _world_size.y + margin)), OUTSIDE)
	draw_rect(Rect2(Vector2.ZERO, _world_size), EDGE, false, 3.0)
