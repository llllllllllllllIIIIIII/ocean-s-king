extends SceneTree

# 临时探针（一次性）：本机那条船的摘要里 `crew_count` 为什么是 0。

func _initialize() -> void:
	var v := Voyage.new()
	v.setup(Sea.GLOBAL_PATH)
	v.encounters_enabled = false
	var first_drop := -1.0
	var t := 0.0
	for i in 200000:
		v.tick(0.5)
		t += 0.5
		if first_drop < 0.0 and v.crew_on_board() != 40:
			first_drop = t
			break
	print("第一次掉人口：t=%s（%.1f 天）　fired=%s" % [
		"未发生" if first_drop < 0.0 else "%.1f" % first_drop,
		(t * VoyageJournal.voyage_time_scale / 86400.0), str(v.fired.keys())])
	var ashore := 0
	var dead := 0
	for m in v.roster.members:
		if m.ashore:
			ashore += 1
		if m.dead:
			dead += 1
	print("members=%d  ashore=%d  dead=%d  crew_on_board=%d  alive=%d"
		% [v.roster.members.size(), ashore, dead, v.crew_on_board(), v._alive_crew_count()])
	print("local_id=%s  local_summary=%s" % [v.fleet.local_id, str(v.local_summary())])
	for row in Settlement.fleet_report(v):
		print("  %s kind=%s crew=%d hull=%.2f" % [
			str(row["name"]), str(row["kind"]), int(row["crew_count"]), float(row["hull_pct"])])
	quit(0)
