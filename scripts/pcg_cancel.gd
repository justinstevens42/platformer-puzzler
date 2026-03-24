extends RefCounted
class_name PcgCancel

## Thread-safe flag for cooperative PCG abort (see LevelGenerator.build_archive).

var _mutex := Mutex.new()
var _cancelled: bool = false


func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()


func is_cancelled() -> bool:
	_mutex.lock()
	var v: bool = _cancelled
	_mutex.unlock()
	return v
