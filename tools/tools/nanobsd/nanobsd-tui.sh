#!/bin/sh
#
# nanobsd-tui.sh -- run nanobsd.sh inside a live-updating TUI box.
#
# ponytail: reuses bsddialog(1)/dialog(1) --infobox, polled in a loop, to
# show nanobsd.sh's pprint output. --prgbox/--programbox would be a single
# call but bsddialog doesn't implement them; --infobox is the one widget
# both tools support, so it's the lazy common denominator. No custom
# curses code, no new hard dependency: falls straight through to a plain
# run if neither tool is on $PATH.
#
set -eu

selfdir=$(dirname "$0")

if command -v bsddialog >/dev/null 2>&1; then
	dlg=bsddialog
elif command -v dialog >/dev/null 2>&1; then
	dlg=dialog
else
	echo "nanobsd-tui: no bsddialog/dialog found, running plain" 1>&2
	exec sh "${selfdir}/nanobsd.sh" "$@"
fi

log=$(mktemp -t nanobsd-tui)
statusfile="$log.status"
trap 'rm -f "$log" "$statusfile"' EXIT

(set +e; sh "${selfdir}/nanobsd.sh" "$@" >"$log" 2>&1; echo $? >"$statusfile") &

rows=$(tput lines)
cols=$(tput cols)
while [ ! -f "$statusfile" ]; do
	"$dlg" --title "nanobsd build (running)" \
	    --infobox "$(tail -n $((rows - 4)) "$log")" "$rows" "$cols"
	sleep 1
done
wait

status=$(cat "$statusfile")
"$dlg" --title "nanobsd build" \
    --msgbox "$(tail -n $((rows - 6)) "$log")

exit status: $status" "$rows" "$cols"
exit "$status"
