class_name InstanceAnimator
extends RefCounted
## Main-renderer resources only. Both passes share one sorted instance buffer;
## the local RenderingDevice used by simulation is never borrowed here.
const SHADER: Shader = preload("res://scripts/presentation/instance_animator.gdshader")
const INSTANCE_FLOATS: int = 12
const TRANSLATION_X: int = 3
const TRANSLATION_Y: int = 7
const CUSTOM_START: int = 8

var bodies: MultiMeshInstance2D
var shadows: MultiMeshInstance2D
var _instances: MultiMesh
var _buffer := PackedFloat32Array()
var _capacity: int = 0

func setup(parent: Node2D, catalog: AnimationCatalog) -> void:
	var metadata: ImageTexture = _clip_texture(catalog)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_instances = MultiMesh.new()
	_instances.transform_format = MultiMesh.TRANSFORM_2D
	_instances.use_custom_data = true
	_instances.mesh = quad
	bodies = _pass(parent, catalog.texture, metadata, false)
	shadows = _pass(parent, load("res://assets/shadow_ellipse.png") as Texture2D, metadata, true)
	shadows.z_index = -2

func _pass(parent: Node2D, texture: Texture2D, metadata: ImageTexture, shadow: bool) -> MultiMeshInstance2D:
	var node := MultiMeshInstance2D.new()
	node.multimesh = _instances
	node.texture = texture
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("clips", metadata)
	material.set_shader_parameter("atlas_size", texture.get_size())
	material.set_shader_parameter("shadow_pass", shadow)
	node.material = material
	parent.add_child(node)
	return node

func set_enabled(enabled: bool) -> void:
	bodies.visible = enabled
	shadows.visible = enabled

func submit(entries: Array[WorldPresentation.DrawEntry], scale: float, world_size: Vector2) -> void:
	if entries.size() > _capacity:
		_capacity = maxi(128, maxi(entries.size(), _capacity * 2))
		_buffer.resize(_capacity * INSTANCE_FLOATS)
		_buffer.fill(0.0)
		for index: int in _capacity:
			_buffer[index * INSTANCE_FLOATS] = 1.0
			_buffer[index * INSTANCE_FLOATS + 5] = 1.0
		_instances.instance_count = _capacity
	# Shaders expand a unit quad. Explicit bounds avoid stale automatic culling;
	# include displayed captures and edge sprites, not just active world bounds.
	var bounds := Rect2(Vector2.ZERO, world_size).grow(64.0 * maxf(scale, 1.0))
	for index: int in entries.size():
		var entry: WorldPresentation.DrawEntry = entries[index]
		var offset: int = index * INSTANCE_FLOATS
		_buffer[offset + TRANSLATION_X] = entry.foot.x
		_buffer[offset + TRANSLATION_Y] = entry.foot.y
		_buffer[offset + CUSTOM_START] = entry.clip_index
		_buffer[offset + CUSTOM_START + 1] = entry.local_animation_ms
		_buffer[offset + CUSTOM_START + 2] = entry.tint.a
		_buffer[offset + CUSTOM_START + 3] = scale
		bounds = bounds.merge(entry.area)
	_instances.custom_aabb = AABB(Vector3(bounds.position.x, bounds.position.y, -1), Vector3(bounds.size.x, bounds.size.y, 2))
	_instances.visible_instance_count = entries.size()
	if not entries.is_empty():
		_instances.buffer = _buffer

func _clip_texture(catalog: AnimationCatalog) -> ImageTexture:
	var maximum_frames: int = 0
	for clip: AnimationCatalog.Clip in catalog.clips:
		maximum_frames = maxi(maximum_frames, clip.rectangles.size())
	var image := Image.create_empty(1 + maximum_frames * 2, catalog.clips.size(), false, Image.FORMAT_RGBAF)
	for index: int in catalog.clips.size():
		var clip: AnimationCatalog.Clip = catalog.clips[index]
		image.set_pixel(0, index, Color(clip.pivot.x, clip.pivot.y, clip.rectangles.size(), 0.0))
		for frame: int in clip.rectangles.size():
			var region: Rect2 = clip.rectangles[frame]
			image.set_pixel(1 + frame * 2, index, Color(region.position.x, region.position.y, region.size.x, region.size.y))
			image.set_pixel(2 + frame * 2, index, Color(clip.cumulative_ms[frame], 0.0, 0.0, 0.0))
	return ImageTexture.create_from_image(image)
