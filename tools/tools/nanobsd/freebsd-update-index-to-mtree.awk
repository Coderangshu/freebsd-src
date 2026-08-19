#!/usr/bin/awk -f

# Convert an octal string to a decimal integer
# strtol(str, NULL, 8).
function octtoint(str, _i, _n) {
	_n = 0
	for (_i = 1; _i <= length(str); _i++) {
		_n = _n * 8 + substr(str, _i, 1)
	}

	return _n
}

# fflagstostr(3)
function fflagstostr(flags, _out) {
	flags = int(flags)
	if (flags == 0) return ""

	# User flags
	if (and(flags, 1))      _out = _out (_out ? "," : "") "uappnd" # 1
	if (and(flags, 2))      _out = _out (_out ? "," : "") "uarch"  # 2
	if (and(flags, 4))      _out = _out (_out ? "," : "") "uchg"   # 4
	if (and(flags, 8))      _out = _out (_out ? "," : "") "nodump" # 8
	if (and(flags, 32))     _out = _out (_out ? "," : "") "uunlnk" # 20

	# System flags
	if (and(flags, 32768))  _out = _out (_out ? "," : "") "sappnd" # 100000
	if (and(flags, 65536))  _out = _out (_out ? "," : "") "sarch"  # 200000
	if (and(flags, 131072)) _out = _out (_out ? "," : "") "schg"   # 400000
	if (and(flags, 262144)) _out = _out (_out ? "," : "") "sunlnk" # 800000

	return _out
}

BEGIN {
	FS = "|"
}

{
	# Skip invalid entries and comments
	if (NF < 7 || $1 ~ /^#/) next

	# mtree(8) expects the relative root entry to be "."
	path = $1
	if (path == "/") {
		sub(/^\//, ".", path)
	} else {
		sub(/^\//, "./", path)
	}

	# Map types
	if ($2 == "d") type = "dir"
	else if ($2 == "L") type = "link"
	else type = "file"

	# Build the mtree string (excluding the path itself)
	# entry = type, uid, gid, mode, flags, link
	entry = sprintf("type=%s uid=%s gid=%s mode=%s", type, $3, $4, $5)

	flags = fflagstostr(octtoint($6))
	if (flags != "") {
		entry = entry " flags=" flags
	}

	if (type == "link" && $7 != "") {
		entry = entry " link=" $7
	}

	# The last entry overrides the existing entry
	entries[path] = entry
}

END {
	# Sort entries
	sort_cmd = "sort"
	for (entry in entries) {
		print entry " " entries[entry] | sort_cmd
	}
	close(sort_cmd)
}
