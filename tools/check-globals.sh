#!/bin/bash
# Finds a class of bug that `luac -p` cannot see.
#
# In Lua, a name referenced above its own `local` declaration does not error at
# compile time - it silently resolves to a global, which is nil at runtime:
#
#     local x = 1 + later    -- `later` here is a nil GLOBAL
#     local later = 2        -- this declaration comes too late
#
# That compiles cleanly and then blows up in Studio with
# "attempt to perform arithmetic on number and nil". Exactly this shipped once
# (ComputerMonitor's height in BuildHospital), so it gets a checker.
#
# Method: compile each file and read the bytecode. Every global access shows up
# as `_ENV "name"`. Any name there that is not a real Roblox/Lua global is
# either a typo or a use-above-declaration; if the same name is also declared
# as a local in the file, it is certainly the latter.
#
# Usage: tools/check-globals.sh          (from the repo root)
# Needs: luac5.4 (any Lua 5.x luac with -l -l works)

set -u

LUAC="${LUAC:-luac5.4}"
if ! command -v "$LUAC" >/dev/null 2>&1; then
	echo "check-globals: $LUAC not found; set LUAC=<path to luac>" >&2
	exit 2
fi

# Globals a Roblox script may legitimately read.
KNOWN='^(game|workspace|Instance|Vector3|Vector2|CFrame|Color3|Enum|UDim|UDim2|Ray|Region3|NumberSequence|NumberRange|ColorSequence|BrickColor|TweenInfo|Random|task|script|require|print|warn|error|assert|pcall|xpcall|select|type|typeof|tostring|tonumber|ipairs|pairs|next|unpack|setmetatable|getmetatable|rawget|rawset|rawequal|rawlen|math|table|string|os|coroutine|utf8|bit32|debug|tick|time|wait|spawn|delay|newproxy|_G|shared|DateTime|Font|Faces|Axes)$'

status=0
for file in src/server/*.lua src/shared/*.lua src/client/*.lua; do
	[ -e "$file" ] || continue
	names=$("$LUAC" -l -l "$file" 2>/dev/null | grep -oP '_ENV "\K[A-Za-z_][A-Za-z0-9_]*' | sort -u)
	for name in $names; do
		echo "$name" | grep -qE "$KNOWN" && continue
		if grep -qE "^[[:space:]]*local[[:space:]]+$name\b" "$file"; then
			echo "BUG  $file: '$name' is read as a global but declared as a local -> used above its declaration"
		else
			echo "WARN $file: unknown global '$name' (typo, or a global that belongs in the known list)"
		fi
		status=1
	done
done

[ $status -eq 0 ] && echo "check-globals: no suspicious global reads."
exit $status
