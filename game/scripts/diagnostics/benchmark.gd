extends SceneTree
## Editor CLI adapter. Exported games enter the same sampler through --benchmark.
func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	root.add_child(BenchmarkSession.new())
