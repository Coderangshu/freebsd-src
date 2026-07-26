#!/bin/sh
#
# nanobsd-tui.sh -- run nanobsd.sh inside a live scrolling TUI box.
#
# ponytail: reuses bsddialog(1)/dialog(1) --prgbox to stream nanobsd.sh's
# pprint output into a bordered, auto-scrolling window. No custom curses
# code, no new hard dependency: falls straight through to a plain run if
# neither tool is on $PATH. Exit code of nanobsd.sh itself is not
# propagated through the dialog widget; add a status-file wrapper if
# that's ever needed.
#
set -eu

selfdir=$(dirname "$0")
cmd="sh ${selfdir}/nanobsd.sh $*"

if command -v bsddialog >/dev/null 2>&1; then
	dlg=bsddialog
elif command -v dialog >/dev/null 2>&1; then
	dlg=dialog
else
	echo "nanobsd-tui: no bsddialog/dialog found, running plain" 1>&2
	exec sh "${selfdir}/nanobsd.sh" "$@"
fi

exec "$dlg" --title "nanobsd build" \
    --prgbox "$cmd" "$(tput lines)" "$(tput cols)"
