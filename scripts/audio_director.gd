class_name AudioDirector
extends Node

# 声音（M8）：两条环境循环 + 四个一次性音效 + 一首主题。
#
# 它**只读 Voyage**，不改任何状态：环境音的音量由风速、航速与天气推出来，
# 一次性音效盯着"状态变了没有"（抛锚、调帆、开炮、修船）。
#
# 素材全部是自产的（`tools/gen_audio.py`），许可见 `assets/audio/LICENSES.md`。

const DIR := "res://assets/audio"

var voyage: Voyage
var ambient_wind: AudioStreamPlayer
var ambient_waves: AudioStreamPlayer
var theme: AudioStreamPlayer
var _sfx: Array[AudioStreamPlayer] = []
var _sfx_streams: Dictionary = {}
var _was_anchored := false
var _last_sail_level := -1
var _last_volleys := 0
var _last_events := 0
var enabled := true


func setup(v: Voyage) -> void:
	voyage = v
	ambient_wind = _loop("amb_wind.wav", -60.0)
	ambient_waves = _loop("amb_waves.wav", -60.0)
	theme = _loop("theme.wav", -60.0)
	for name in ["sfx_anchor", "sfx_sail", "sfx_cannon", "sfx_hammer"]:
		var st := _load(name + ".wav")
		if st != null:
			_sfx_streams[name] = st
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_sfx.append(p)
	_was_anchored = v.orders.anchored
	_last_sail_level = int(v.orders.sail_level)


func _load(file: String) -> AudioStream:
	var path := "%s/%s" % [DIR, file]
	if not ResourceLoader.exists(path):
		return null
	return load(path)


func _loop(file: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var st := _load(file)
	if st != null:
		if st is AudioStreamWAV:
			(st as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
		p.stream = st
		p.volume_db = db
		add_child(p)
		p.play()
	return p


func play(name: String, db := -6.0) -> void:
	if not enabled or not _sfx_streams.has(name):
		return
	for p in _sfx:
		if not p.playing:
			p.stream = _sfx_streams[name]
			p.volume_db = db
			p.play()
			return


func set_enabled(on: bool) -> void:
	enabled = on
	for p in _sfx:
		if not on:
			p.stop()
	if ambient_wind != null:
		ambient_wind.stream_paused = not on
	if ambient_waves != null:
		ambient_waves.stream_paused = not on
	if theme != null:
		theme.stream_paused = not on


func tick(_delta: float) -> void:
	if voyage == null or not enabled:
		return
	# ① 环境：风看真风速与天气，浪看航速与天气
	var tws := voyage.wind.tws_ms * voyage.weather.wind_mult()
	var speed := absf(voyage.ship.speed_ms())
	var storm := 1.0 if voyage.weather.state_id == "storm" else \
		(0.6 if voyage.weather.state_id == "squall" else 0.0)
	if ambient_wind != null:
		ambient_wind.volume_db = _db(clampf(0.15 + tws / 18.0 + storm * 0.35, 0.0, 1.0))
	if ambient_waves != null:
		ambient_waves.volume_db = _db(clampf(0.10 + speed / 4.0 * 0.5 + storm * 0.4, 0.0, 1.0))
	# ② 一次性：抛锚 / 调帆 / 开炮 / 修船
	if voyage.orders.anchored != _was_anchored:
		_was_anchored = voyage.orders.anchored
		play("sfx_anchor")
	if int(voyage.orders.sail_level) != _last_sail_level:
		_last_sail_level = int(voyage.orders.sail_level)
		play("sfx_sail", -12.0)
	if voyage.battle != null:
		var v := int(voyage.battle.stats()["volleys"])
		if v > _last_volleys:
			_last_volleys = v
			play("sfx_cannon", -4.0)
	if voyage.society.event_count > _last_events:
		_last_events = voyage.society.event_count
		play("sfx_hammer", -14.0)


static func _db(ratio: float) -> float:
	if ratio <= 0.001:
		return -60.0
	return linear_to_db(clampf(ratio, 0.0, 1.0))
