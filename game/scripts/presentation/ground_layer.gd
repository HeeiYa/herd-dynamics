class_name GroundLayer
extends Node2D
## One nearest-filtered color texel per resource cell. Color represents actual
## coverage at the displayed simulation tick; no decorative food or wall clock.
const LEVELS: int = 256
const DRY := Color("c7b27a")
const MID := Color("a3b264")
const LUSH := Color("6f9a48")
const OUTSIDE := Color("3e4a34")
const EDGE := Color("5d6b45")

var _resources: ResourceGrid
var _world_size: Vector2
var _cell_size: float
var _image: Image
var _texture: ImageTexture
var _levels: PackedInt32Array = PackedInt32Array()

func configure(resources: ResourceGrid, world_size: Vector2) -> void:
	_resources = resources
	_world_size = world_size
	_cell_size = resources.cell_size
	_levels.resize(resources.cell_count)
	_levels.fill(-1)
	_image = Image.create_empty(resources.columns, resources.rows, false, Image.FORMAT_RGB8)
	_image.fill(DRY)
	_texture = ImageTexture.create_from_image(_image)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	queue_redraw()

func bind_resources(resources: ResourceGrid, world_size: Vector2) -> void:
	if _world_size != world_size or _cell_size != resources.cell_size or _image.get_width() != resources.columns or _image.get_height() != resources.rows:
		configure(resources, world_size)
	else:
		_resources = resources

func clear_levels() -> void:
	_levels.fill(-1)

func update_at(display_tick: float) -> void:
	var dirty: bool = false
	var earlier: int = floori(display_tick)
	var later: int = ceili(display_tick)
	for cell: int in _resources.cell_count:
		var amount: float = lerpf(_resources.get_effective_amount(cell, earlier), _resources.get_effective_amount(cell, later), display_tick - earlier)
		var level: int = clampi(roundi(amount * (LEVELS - 1)), 0, LEVELS - 1)
		if _levels[cell] == level:
			continue
		_levels[cell] = level
		_image.set_pixel(cell % _resources.columns, cell / _resources.columns, _level_color(level))
		dirty = true
	if dirty:
		_texture.update(_image)

static func _level_color(level: int) -> Color:
	var amount: float = float(level) / (LEVELS - 1)
	if amount < 0.4:
		return DRY.lerp(MID, amount / 0.4)
	return MID.lerp(LUSH, (amount - 0.4) / 0.6)

func _draw() -> void:
	if _resources == null:
		return
	var margin: float = 600.0
	draw_rect(Rect2(-Vector2.ONE * margin, _world_size + Vector2.ONE * margin * 2.0), OUTSIDE)
	# Crop the final texel rather than stretching partial boundary cells.
	var texel_extent: Vector2 = _world_size / _cell_size
	draw_texture_rect_region(_texture, Rect2(Vector2.ZERO, _world_size), Rect2(Vector2.ZERO, texel_extent))
	draw_rect(Rect2(Vector2.ZERO, _world_size), EDGE, false, 3.0)

## Adopt an already prepared back image; no cell walk at the commit boundary.
func commit_image(resources: ResourceGrid, world_size: Vector2, image: Image, levels: PackedInt32Array) -> void:
	var resized: bool = _image.get_size() != image.get_size()
	_resources = resources
	_world_size = world_size
	_cell_size = resources.cell_size
	_image = image
	_levels = levels
	if resized:
		_texture = ImageTexture.create_from_image(image)
	else:
		_texture.update(image)
	queue_redraw()
