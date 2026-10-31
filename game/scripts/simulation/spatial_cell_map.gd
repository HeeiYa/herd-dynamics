class_name SpatialCellMap
extends RefCounted
## Maps world cell coordinates to phase-local array slots. Sparse storage uses
## occupied 4x4 blocks; block slots and links never survive a rebuild.
const BLOCK_WIDTH: int = 4
const BLOCK_CELLS: int = BLOCK_WIDTH * BLOCK_WIDTH
const HASH_MULTIPLIER: int = 73856093
var columns: int
var rows: int
var sparse: bool
var storage_count: int
var block_columns: int
var _blocks: Dictionary[int, int] = {}
var _keys := PackedInt32Array()
var _gpu_lookup := PackedInt32Array()

func _init(width: int, height: int, use_sparse: bool) -> void:
	columns = width
	rows = height
	sparse = use_sparse
	block_columns = ceili(float(columns) / BLOCK_WIDTH)
	storage_count = 0 if sparse else columns * rows

func rebuild(store: AgentStore, cell_size: float) -> void:
	if not sparse:
		return
	_blocks.clear()
	_keys.clear()
	for dense: int in store.count:
		if store.alive[dense] == 0 or store.held[dense] != 0:
			continue
		var position: Vector2 = store.position_current[dense]
		var x: int = clampi(floori(position.x / cell_size), 0, columns - 1)
		var y: int = clampi(floori(position.y / cell_size), 0, rows - 1)
		var key: int = (y / BLOCK_WIDTH) * block_columns + x / BLOCK_WIDTH
		if not _blocks.has(key):
			_blocks[key] = _keys.size()
			_keys.append(key)
	storage_count = _keys.size() * BLOCK_CELLS

func slot(x: int, y: int) -> int:
	if not sparse:
		return y * columns + x
	var key: int = (y / BLOCK_WIDTH) * block_columns + x / BLOCK_WIDTH
	var block: int = _blocks.get(key, -1)
	if block < 0:
		return -1
	return block * BLOCK_CELLS + (y % BLOCK_WIDTH) * BLOCK_WIDTH + x % BLOCK_WIDTH

## Open-addressed integer table, shared with the shader's cell_slot(). There
## are at least twice as many buckets as occupied blocks, so probing terminates.
## Keys are spatial coordinates, never actor identities or persistent handles.
func gpu_lookup() -> PackedInt32Array:
	var buckets: int = 2
	while buckets < _keys.size() * 2:
		buckets *= 2
	_gpu_lookup.resize(buckets * 2)
	_gpu_lookup.fill(-1)
	var mask: int = buckets - 1
	for block: int in _keys.size():
		var key: int = _keys[block]
		var bucket: int = (key * HASH_MULTIPLIER) & mask
		while _gpu_lookup[bucket * 2] >= 0:
			bucket = (bucket + 1) & mask
		_gpu_lookup[bucket * 2] = key
		_gpu_lookup[bucket * 2 + 1] = block
	return _gpu_lookup
