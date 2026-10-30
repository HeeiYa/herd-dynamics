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
	if _theme != null:
		return _theme
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "sans-serif"])
	theme.default_font = font
	theme.default_font_size = 14
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "CheckBox", INK)
	theme.set_color("font_hover_color", "CheckBox", INK)
	theme.set_color("font_pressed_color", "CheckBox", INK)
	for type: String in ["Button", "OptionButton"]:
		theme.set_color("font_color", type, INK)
		theme.set_color("font_hover_color", type, INK)
		theme.set_color("font_pressed_color", type, Color.WHITE)
		theme.set_color("font_hover_pressed_color", type, Color.WHITE)
		theme.set_color("font_focus_color", type, INK)
		theme.set_color("font_disabled_color", type, DISABLED)
		theme.set_stylebox("normal", type, _box(PAPER, PAPER_EDGE))
		theme.set_stylebox("hover", type, _box(Color("fbf4e6"), ACCENT_SOFT))
		theme.set_stylebox("pressed", type, _box(ACCENT, ACCENT.darkened(0.15)))
		theme.set_stylebox("hover_pressed", type, _box(ACCENT.lightened(0.08), ACCENT.darkened(0.15)))
		theme.set_stylebox("disabled", type, _box(PAPER_DEEP, PAPER_DEEP))
		theme.set_stylebox("focus", type, _outline(ACCENT_SOFT))
	theme.set_stylebox("panel", "PanelContainer", panel_box())
	theme.set_stylebox("panel", "PopupMenu", panel_box())
	theme.set_color("font_color", "PopupMenu", INK)
	theme.set_color("font_hover_color", "PopupMenu", INK)
	theme.set_stylebox("hover", "PopupMenu", _box(ACCENT_SOFT, ACCENT_SOFT))
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_stylebox("normal", "LineEdit", _box(Color("fffaf0"), PAPER_EDGE))
	theme.set_stylebox("focus", "LineEdit", _outline(ACCENT))
	theme.set_stylebox("slider", "HSlider", _track())
	theme.set_stylebox("grabber_area", "HSlider", _track(ACCENT_SOFT))
	theme.set_stylebox("grabber_area_highlight", "HSlider", _track(ACCENT))
	theme.set_stylebox("separator", "HSeparator", _line())
	theme.set_constant("separation", "HSeparator", 10)
	for type: String in ["TabBar", "TabContainer"]:
		theme.set_color("font_selected_color", type, INK)
		theme.set_color("font_unselected_color", type, INK_SOFT)
		theme.set_color("font_hovered_color", type, INK)
		theme.set_stylebox("tab_selected", type, _tab(PAPER, ACCENT))
		theme.set_stylebox("tab_unselected", type, _tab(PAPER_DEEP, PAPER_DEEP))
		theme.set_stylebox("tab_hovered", type, _tab(Color("fbf4e6"), ACCENT_SOFT))
	var page := StyleBoxFlat.new()
	page.bg_color = Color(PAPER, 0.0)
	page.content_margin_top = 10
	theme.set_stylebox("panel", "TabContainer", page)
	theme.set_color("font_color", "RichTextLabel", INK)
	theme.set_color("default_color", "RichTextLabel", INK)
	theme.set_color("font_color", "TooltipLabel", INK)
	theme.set_stylebox("panel", "TooltipPanel", _box(Color("fffaf0"), PAPER_EDGE))
	_theme = theme
	return theme

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
