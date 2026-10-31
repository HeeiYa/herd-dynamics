class_name UiStyle
extends RefCounted
## Warm, natural observer palette shared by the HUD, overlays and ground.
## Colors carry meaning together with shapes or line styles, never alone.

const PAPER := Color("f4ecdc")
const PAPER_DEEP := Color("e8dcc3")
const PAPER_EDGE := Color("cdb995")
const INK := Color("3b3127")
const INK_SOFT := Color("7a6a55")
const ACCENT := Color("c4703a")
const ACCENT_SOFT := Color("e9b98c")
const OLIVE := Color("6f8442")
const DISABLED := Color("b8ab95")
const BACKDROP := Color("2f3a2b")

# World overlay colors.
const SELECTION := Color("fff1c4")
const DESTINATION := Color("f6d36b")
const TARGET_DIRECT := Color("f4f0e6")
const TARGET_SHARED := Color("9fd0e8")
const PERCEPTION := Color(1.0, 0.97, 0.88, 0.5)
const PROTECTION := Color(0.55, 0.78, 0.98, 0.55)
const HOVER := Color(1.0, 0.95, 0.75, 0.9)
const VALID_DROP := Color("b8e08a")
const INVALID_DROP := Color("e07b62")
const SPECIES := [Color("efe6d2"), Color("9a8f86"), Color("d39a52")]

static var _theme: Theme

static func interface_theme() -> Theme:
	return preload("res://scenes/ui/observer_theme.tres")

static func panel_box(alpha: float = 0.95) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(PAPER, alpha)
	box.border_color = PAPER_EDGE
	box.set_border_width_all(1)
	box.set_corner_radius_all(12)
	box.shadow_color = Color(0.1, 0.08, 0.04, 0.22)
	box.shadow_size = 6
	box.shadow_offset = Vector2(0, 2)
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	return box

static func _box(fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 5
	box.content_margin_bottom = 5
	return box

static func _outline(border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.border_color = border
	box.set_border_width_all(2)
	box.set_corner_radius_all(8)
	return box

static func _track(fill: Color = PAPER_DEEP) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(3)
	box.content_margin_top = 3
	box.content_margin_bottom = 3
	return box

static func _line() -> StyleBoxLine:
	var line := StyleBoxLine.new()
	line.color = PAPER_EDGE
	line.thickness = 1
	return line

static func _tab(fill: Color, underline: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = underline
	box.border_width_bottom = 2
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	return box
