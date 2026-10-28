class_name GrassChunk
extends Node2D
## One retained draw list per small static patch; only visual threshold changes redraw it.
var cells: PackedInt32Array = PackedInt32Array()
var levels: PackedInt32Array = PackedInt32Array()
var resources: ResourceGrid
var rich_texture: Texture2D
var grazed_texture: Texture2D
var world_size: Vector2

func configure(grid: ResourceGrid, indices: PackedInt32Array, rich: Texture2D, grazed: Texture2D, size: Vector2) -> void:
	resources = grid
	cells = indices
	rich_texture = rich
	grazed_texture = grazed
	world_size = size
	levels.resize(cells.size())
	levels.fill(-1)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED

func update_at(display_tick: float) -> void:
	var dirty: bool = false
	var earlier: int = floori(display_tick)
	var later: int = ceili(display_tick)
	for index: int in cells.size():
		var cell: int = cells[index]
		var amount: float = lerpf(resources.get_effective_amount(cell, earlier), resources.get_effective_amount(cell, later), display_tick - earlier)
		var level: int = clampi(floori(amount * 4.0), 0, 3)
		if levels[index] != level:
			levels[index] = level
			dirty = true
	if dirty:
		queue_redraw()

func _draw() -> void:
	for index: int in cells.size():
		var area: Rect2 = resources.cell_bounds(cells[index])
		var level: int = maxi(0, levels[index])
		if level == 0:
			draw_texture_rect(grazed_texture, area, true)
		else:
			var brightness: float = 0.78 + level * 0.0733
			draw_texture_rect(rich_texture, area, true, Color(brightness, brightness, brightness))
