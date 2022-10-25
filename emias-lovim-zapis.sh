#!/usr/bin/env bash

set -e
set -u

CHROMIUM=chromium-browser

TMPDIR="$(mktemp -d)"
export TMPDIR
PID_LIST="$(mktemp)"

_cleanup(){
	for i in $(tac "$PID_LIST")
	do
		kill "$i" 2>/dev/null || :
		kill -9 "$i" 2>/dev/null || :
	done
	rm -fr "$TMPDIR"
}
trap '_cleanup' EXIT

# Run a process in detached form
# We can use systemd-run here, but let's keep things simplier and crossplatform for now.
# Linux and DragonFlyBSD have /proc/$PID by default,
# FreeBSD does not have /proc by default, but it can be turned on.
# https://stackoverflow.com/a/1024937
_run(){
	"$@" &
	local PID=$!
	_sleep 1
	if [ ! -d /proc/"$PID" ]; then
		echo "command $* has probably failed"
		return 1
	fi
	echo "$PID" >> "$PID_LIST"
}

_gen_virt_display(){
	local d
	while true
	do
		d=$(( ( RANDOM % 5000 )  + 1 ))
		# XXX /tmp/.X11-unix may be different in theory,
		# I don't know how to find this directory
		if ! test -e /tmp/.X11-unix/X"$d" ; then
			d=:"$d"
			break
		fi
	done
	echo "$d"
}

# $1: resolution
# $2: screen
# $3: X server type, Xephyr or Xvfb
# example: _xserver_start 1024x720 :10 Xephyr
_xserver_start(){
	case "$3" in
		Xephyr ) _run Xephyr -br -ac -noreset -screen "$1" "$2" ;;
		Xvfb ) _run Xvfb "$2" -screen 0 "$1"x24 ;;
	esac
	DISPLAY="$2" _run xfwm4
}

SLEEP_KOEF=1
_sleep(){
	local a="$1"
	sleep $((a*SLEEP_KOEF))
}

# XXX sometimes _xclip fails with:
# Error: target STRING not available
# Retry for two times
_xclip(){
	local o
	if o="$(xclip "$@")"
	then
		echo "$o"
		return 0
	fi
	if o="$(xclip "$@")"
	then
		echo "$o"
	else
		return 1
	fi
}

# $1: initial wait
# $2: text to search for on the page
# $3: how long to wait before retrying search
# $4: max retries
# $5: $DISPLAY
# $6: X coordinate where to click to remove selection by Ctrl+A
# $7: Y coordinate where to click to remove selection by Ctrl+A
_wait_until_page_is_loaded(){
	_sleep "$1"
	local c=0
	while :
	do
		if [ "$c" -gt "$4" ]; then
			return 1
		fi
		local text
		if ! text="$(DISPLAY="$5" xdotool key Control+a Control+c && \
		             DISPLAY="$5" _xclip -o -sel c && \
					 DISPLAY="$5" xdotool mousemove "$6" "$7" click 1 \
					)"
		then
			c=$((++c))
			_sleep "$3"
			continue
		else
			# shellcheck disable=SC2076
			if [[ "$text" =~ "$2" ]]
			then
				break
			else
				c=$((++c))
				_sleep "$3"
				continue
			fi
		fi
	done
}

_main(){
	local X
	X="$(_gen_virt_display)"
	local chromium_profile_dir
	chromium_profile_dir="$(mktemp -d)"
	# start X server and a window manager inside it
	_xserver_start 1024x720 "$X" Xephyr
	DISPLAY="$X" _run "$CHROMIUM" \
		--new-window \
		--start-maximized \
		--no-default-browser-check \
		--user-data-dir="$chromium_profile_dir" \
		"about:blank" \
		2>/dev/null
	_sleep 5
	# open a new tab in already launched Chromium
	DISPLAY="$X" "$CHROMIUM" --user-data-dir="$chromium_profile_dir" --new-tab https://emias.info
	_wait_until_page_is_loaded 10 "Запись к врачу" 3 12 "$X" 120 170
	echo ""
	read -p "=> Войдите в ЕМИАС и нажмите Enter..."
	# закрываем открытую копию emias.info (благодаря висящей открытой about:blank браузер не закрывается)
	DISPLAY="$X" xdotool key Control+w
	# "Записаться"
	DISPLAY="$X" "$CHROMIUM" --user-data-dir="$chromium_profile_dir" --new-tab https://emias.info/appointment/create
	_wait_until_page_is_loaded 6 "Выберите полис" 3 12 "$X" 120 170
	while true
	do
		# Первый (и единственный) мед. полис ОМС
		DISPLAY="$X" xdotool mousemove 360 425 click 1
		_wait_until_page_is_loaded 3 "Специальности" 3 12 "$X" 120 170
		# Первое направление (венозная кровь)
		DISPLAY="$X" xdotool mousemove 630 450 click 1
		_sleep 6
		DISPLAY="$X" xdotool key Control+a Control+c
		_sleep 1
		local text
		text="$(DISPLAY="$X" _xclip -o -sel c)"
		#if [ -n "$text" ] && ! [[ "$text" =~ "Запись недоступна" ]]; then
		if [ -n "$text" ] && { [[ "$text" =~ "с 26 окт, ср" ]] || [[ "$text" =~ "егодня" ]] ;} ; then
			baka-mplayer '/home/mikhailnov/Музыка/SHAMAN - Я РУССКИЙ (музыка и слова - SHAMAN) [FAPwIEWzqJE].webm'
			_sleep 300
			continue
		fi
		# возврат назад на страницу с выбором направления/врача
		DISPLAY="$X" xdotool key F5
		_wait_until_page_is_loaded 5 "Выберите полис" 3 12 "$X" 120 170
	done
}

_main
