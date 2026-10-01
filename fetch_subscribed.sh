#!/usr/bin/env bash
# Usage: ./fetch_subscribed.sh [-missing] [-c|--copy] [--acf FILE] <appid> [firefox_profile_dir]
#
#   -missing, --missing   Only output mods that are NOT already listed in the
#                         game's appworkshop_<appid>.acf (i.e. not installed).
#                         Writes ~/Downloads/<appid>_missing.txt instead.
#   -c, --copy            Copy the links to the clipboard instead of writing a
#                         file (uses wl-copy on Wayland, xclip/xsel on X11).
#   --acf FILE            Use this .acf file instead of auto-locating it.
#
# Pulls the steamLoginSecure session cookie out of Firefox, uses it to
# fetch every page of
#   https://steamcommunity.com/my/myworkshopfiles/?appid=<appid>&browsefilter=mysubscriptions
# as you (logged in), and writes the deduped links to
#   ~/Downloads/<appid>_subscribed.txt
#
# Checks, in order: legacy native (~/.mozilla/firefox), the newer XDG-style
# native layout (Firefox 147+ splits profile data across ~/.config and
# ~/.local/share), Flatpak, Snap, and finally a bounded search of your
# whole home directory as a last resort. Prints exactly what it tried and
# what it found/didn't find at each step.
#
# Requirements: sqlite3, curl
# You must already be logged into steamcommunity.com in Firefox.
#
# SECURITY NOTE: steamLoginSecure is a live session token for your Steam
# account. This script only holds it in memory / a temp dir deleted on
# exit, and never prints or writes it anywhere.

set -euo pipefail

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }
ok()   { printf '  [ok] %s\n' "$*" >&2; }
no()   { printf '  [--] %s\n' "$*" >&2; }

usage() {
    echo "Usage: $0 [-missing] [-c|--copy] [--acf FILE] <appid> [firefox_profile_dir]" >&2
}

missing_only=0
copy_mode=0
acf_override=""
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        -missing|--missing|-m) missing_only=1 ;;
        -c|--copy) copy_mode=1 ;;
        --acf)
            shift
            acf_override="${1:-}"
            [ -n "$acf_override" ] || { echo "--acf needs a file path" >&2; exit 1; }
            ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *) positional+=("$1") ;;
    esac
    shift
done

if [ ${#positional[@]} -lt 1 ]; then
    usage
    exit 1
fi

appid="${positional[0]}"
profile_dir_override="${positional[1]:-}"

command -v sqlite3 >/dev/null || { say "sqlite3 not found — install it with: sudo dnf install sqlite"; exit 1; }
command -v curl    >/dev/null || { say "curl not found — install it with: sudo dnf install curl"; exit 1; }

# Pick a clipboard tool. Sets the CLIP_CMD array (empty on failure).
# Prefers whatever matches the current session type, then tries the rest.
detect_clipboard() {
    CLIP_CMD=()
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null; then
        CLIP_CMD=(wl-copy)
    elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null; then
        CLIP_CMD=(xclip -selection clipboard)
    elif [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null; then
        CLIP_CMD=(xsel --clipboard --input)
    elif command -v wl-copy >/dev/null; then
        CLIP_CMD=(wl-copy)
    elif command -v xclip >/dev/null; then
        CLIP_CMD=(xclip -selection clipboard)
    elif command -v xsel >/dev/null; then
        CLIP_CMD=(xsel --clipboard --input)
    fi
}

# Locate steamapps/workshop/appworkshop_<appid>.acf across Steam installs
# (native, Flatpak, Snap) and every extra library folder in libraryfolders.vdf.
find_acf() {
    local appid="$1" r f lib
    local roots=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        "$HOME/snap/steam/common/.local/share/Steam"
    )
    local libs=()

    for r in "${roots[@]}"; do
        [ -d "$r/steamapps" ] || continue
        libs+=("$r")
        f="$r/steamapps/libraryfolders.vdf"
        if [ -f "$f" ]; then
            while IFS= read -r lib; do
                [ -n "$lib" ] && libs+=("$lib")
            done < <(grep -oP '^\s*"path"\s+"\K[^"]+' "$f" || true)
        fi
    done

    for lib in "${libs[@]}"; do
        f="$lib/steamapps/workshop/appworkshop_${appid}.acf"
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
        say "  checked: $f (not there)"
    done
    return 1
}

# Print workshop item IDs listed under WorkshopItemsInstalled in an .acf.
# Falls back to every bare-numeric key in the file if that section is absent.
read_acf_ids() {
    local acf="$1" ids
    ids=$(awk '
        /"WorkshopItemsInstalled"/ { in_s=1; next }
        /"WorkshopItemDetails"/    { in_s=0; next }
        in_s && /^[ \t]*"[0-9]+"[ \t\r]*$/ { gsub(/[^0-9]/, ""); print }
    ' "$acf" | sort -u)
    if [ -z "$ids" ]; then
        ids=$(grep -oP '^\s*"\K[0-9]+(?="\s*\r?$)' "$acf" | sort -u || true)
    fi
    printf '%s\n' "$ids"
}

# Figure out which profile folder is "the" default one inside a Firefox
# base dir, using installs.ini / profiles.ini, falling back to a lone
# *.default-release folder if that's all there is.
detect_default_profile() {
    local base="$1"
    local rel=""

    if [ -f "$base/installs.ini" ]; then
        rel=$(sed 's/\r$//' "$base/installs.ini" | awk -F'=' '/^Default=/{print $2; exit}' || true)
    fi

    if [ -z "$rel" ] && [ -f "$base/profiles.ini" ]; then
        rel=$(sed 's/\r$//' "$base/profiles.ini" | awk -F'=' '
            /^\[/{ if (isdef && path!="") print path; path=""; isdef=0; next }
            /^Path=/{ path=$2 }
            /^Default=1/{ isdef=1 }
            END{ if (isdef && path!="") print path }
        ' || true)
    fi

    if [ -n "$rel" ]; then
        if [[ "$rel" = /* ]]; then
            echo "$rel"
        else
            echo "$base/$rel"
        fi
        return
    fi

    local matches
    matches=$(find "$base" -maxdepth 1 -type d \( -iname "*.default-release" -o -iname "*.default" \) 2>/dev/null || true)
    if [ "$(printf '%s\n' "$matches" | grep -c .)" -eq 1 ]; then
        echo "$matches"
        return
    fi

    local all_profiles
    all_profiles=$(find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -vE '/(Crash Reports|Pending Pings)$' || true)
    if [ "$(printf '%s\n' "$all_profiles" | grep -c .)" -eq 1 ]; then
        echo "$all_profiles"
        return
    fi

    echo ""
}

# Sets globals LOGIN_SECURE / SESSION_ID (empty on failure). Must be
# called directly (not via $(...)) so the globals survive.
extract_cookie() {
    local profile="$1"
    local tmp
    tmp=$(mktemp -d)

    cp "$profile/cookies.sqlite" "$tmp/" 2>/dev/null || true
    cp "$profile/cookies.sqlite-wal" "$tmp/" 2>/dev/null || true
    cp "$profile/cookies.sqlite-shm" "$tmp/" 2>/dev/null || true

    if [ ! -f "$tmp/cookies.sqlite" ]; then
        LOGIN_SECURE=""
        SESSION_ID=""
        rm -rf "$tmp"
        return
    fi

    LOGIN_SECURE=$(sqlite3 "$tmp/cookies.sqlite" \
        "SELECT value FROM moz_cookies WHERE host LIKE '%steamcommunity.com' AND name='steamLoginSecure' AND expiry > strftime('%s','now') ORDER BY expiry DESC LIMIT 1;" 2>/dev/null || true)
    SESSION_ID=$(sqlite3 "$tmp/cookies.sqlite" \
        "SELECT value FROM moz_cookies WHERE host LIKE '%steamcommunity.com' AND name='sessionid' AND expiry > strftime('%s','now') ORDER BY expiry DESC LIMIT 1;" 2>/dev/null || true)

    rm -rf "$tmp"
}

CLIP_CMD=()
if [ "$copy_mode" -eq 1 ]; then
    detect_clipboard
    if [ ${#CLIP_CMD[@]} -eq 0 ]; then
        say "No clipboard tool found. Install one:"
        say "  Wayland: sudo dnf install wl-clipboard"
        say "  X11:     sudo dnf install xclip"
        exit 1
    fi
fi

installed_ids=""
if [ "$missing_only" -eq 1 ]; then
    step "Locating appworkshop_${appid}.acf"
    if [ -n "$acf_override" ]; then
        acf_file="$acf_override"
        [ -f "$acf_file" ] || { say "  [--] file not found: $acf_file"; exit 1; }
    elif ! acf_file=$(find_acf "$appid"); then
        say "  [--] couldn't find appworkshop_${appid}.acf in any Steam library."
        say "       Pass it explicitly with: --acf /path/to/appworkshop_${appid}.acf"
        exit 1
    fi
    ok "using $acf_file"
    installed_ids=$(read_acf_ids "$acf_file")
    ok "$(printf '%s\n' "$installed_ids" | grep -c . || true) installed item(s) listed in the .acf"
fi

FOUND_PROFILE=""
FOUND_LABEL=""
LOGIN_SECURE=""
SESSION_ID=""

try_candidate() {
    local base="$1" label="$2"
    step "Trying $label"
    say "  looking in: $base"

    if [ ! -d "$base" ]; then
        no "directory not found — not installed/used this way on your system"
        return 1
    fi
    ok "directory exists"

    local profile
    profile=$(detect_default_profile "$base")
    if [ -z "$profile" ]; then
        no "couldn't determine a default profile automatically"
        local listing
        listing=$(find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true)
        if [ -n "$listing" ]; then
            say "  profile folders seen here (pass one of these as the 2nd argument):"
            while IFS= read -r d; do say "    - $d"; done <<< "$listing"
        fi
        return 1
    fi
    ok "profile: $profile"

    if [ ! -f "$profile/cookies.sqlite" ]; then
        no "no cookies.sqlite in that profile"
        return 1
    fi
    ok "cookies.sqlite present"

    extract_cookie "$profile"
    if [ -z "$LOGIN_SECURE" ]; then
        no "no steamLoginSecure cookie — you're likely not logged into steamcommunity.com in this profile"
        return 1
    fi
    ok "active steamcommunity.com session found"

    FOUND_PROFILE="$profile"
    FOUND_LABEL="$label"
    return 0
}

# Last resort: don't guess paths at all, just find the real file.
try_deep_search() {
    step "Last resort: searching your home directory for cookies.sqlite"
    say "  (bounded search, may take a few seconds)"

    local hit
    hit=$(find "$HOME" -maxdepth 8 -iname "cookies.sqlite" -ipath "*mozilla*" 2>/dev/null | head -n1 || true)
    if [ -z "$hit" ]; then
        no "no cookies.sqlite found under any mozilla-related folder in your home directory"
        return 1
    fi

    local profile
    profile=$(dirname "$hit")
    ok "found: $hit"

    extract_cookie "$profile"
    if [ -z "$LOGIN_SECURE" ]; then
        no "no steamLoginSecure cookie in it — are you logged into steamcommunity.com in Firefox?"
        return 1
    fi
    ok "active steamcommunity.com session found"

    FOUND_PROFILE="$profile"
    FOUND_LABEL="found via home-directory search"
    return 0
}

success=0
if [ -n "$profile_dir_override" ]; then
    if try_candidate "$profile_dir_override" "manually specified profile"; then
        success=1
    fi
else
    xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
    xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
    candidates=(
        "$HOME/.mozilla/firefox|native Firefox (legacy ~/.mozilla layout)"
        "$xdg_config/mozilla/firefox|native Firefox (newer XDG config layout, Firefox 147+)"
        "$xdg_data/mozilla/firefox|native Firefox (newer XDG data layout, Firefox 147+)"
        "$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox|Flatpak Firefox"
        "$HOME/snap/firefox/common/.mozilla/firefox|Snap Firefox"
    )
    for entry in "${candidates[@]}"; do
        base="${entry%%|*}"
        label="${entry#*|}"
        if try_candidate "$base" "$label"; then
            success=1
            break
        fi
    done

    if [ "$success" -ne 1 ]; then
        if try_deep_search; then
            success=1
        fi
    fi
fi

if [ "$success" -ne 1 ]; then
    say ""
    say "Could not find a working Steam session in any known Firefox location."
    say "Make sure you're logged into steamcommunity.com in Firefox, then either:"
    say "  1) rerun this script as-is, or"
    say "  2) locate your profile manually and pass it directly:"
    say "       find ~ -maxdepth 8 -iname 'cookies.sqlite' 2>/dev/null"
    say "       $0 $appid /path/to/that/profile/dir"
    exit 1
fi

say ""
say "Using session from: $FOUND_LABEL"
say "  ($FOUND_PROFILE)"

cookie_header="steamLoginSecure=${LOGIN_SECURE}"
[ -n "$SESSION_ID" ] && cookie_header="${cookie_header}; sessionid=${SESSION_ID}"

step "Fetching subscribed items for appid $appid"

fetch_tmp=$(mktemp -d)
trap 'rm -rf "$fetch_tmp"' EXIT

if [ "$copy_mode" -eq 1 ]; then
    # temp file only; deleted on exit by the trap
    outfile="$fetch_tmp/clipboard.txt"
else
    mkdir -p "$HOME/Downloads"
    if [ "$missing_only" -eq 1 ]; then
        outfile="$HOME/Downloads/${appid}_missing.txt"
    else
        outfile="$HOME/Downloads/${appid}_subscribed.txt"
    fi
fi
all_file="$fetch_tmp/all_links.txt"

page=1
max_pages=20
while [ "$page" -le "$max_pages" ]; do
    url="https://steamcommunity.com/my/myworkshopfiles/?appid=${appid}&browsefilter=mysubscriptions&p=${page}&numperpage=30"
    page_file="$fetch_tmp/page_${page}.html"

    # -L: /my/... always 302s to your canonical profile URL, even when
    # logged in correctly, so redirects must be followed to reach the
    # actual listing rather than just seeing that first 302.
    result=$(curl -s -L --max-redirs 5 -o "$page_file" -w '%{http_code} %{url_effective}' \
        -b "$cookie_header" \
        --compressed \
        -A "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0" \
        "$url" || true)
    http_code="${result%% *}"
    effective_url="${result#* }"

    if [ "$http_code" != "200" ]; then
        say "  page $page: HTTP $http_code at $effective_url — stopping"
        break
    fi

    # Steam pages embed g_steamID as your SteamID64 when logged in, or
    # literally "false" when not — a much more direct signal than status
    # codes or page size for telling "not logged in" apart from
    # "logged in, genuinely nothing here".
    if [ "$page" -eq 1 ] && grep -q 'g_steamID = false' "$page_file" 2>/dev/null; then
        say "  page 1: Steam reports you as NOT logged in (g_steamID = false)"
        say "  landed on: $effective_url"
        say "  the steamLoginSecure cookie was found in Firefox but Steam isn't"
        say "  honoring it here — most likely it's stale. Reload steamcommunity.com"
        say "  in Firefox (or log out/back in) to refresh it, then rerun."
        break
    fi

    ids=$(grep -oP 'filedetails/\?id=\K[0-9]+' "$page_file" || true)
    if [ -z "$ids" ]; then
        say "  page $page: 0 items — stopping"
        say "  landed on: $effective_url"
        break
    fi
    say "  page $page: $(printf '%s\n' "$ids" | sort -u | wc -l) item(s)"
    page=$((page + 1))
done

grep -hoP 'filedetails/\?id=\K[0-9]+' "$fetch_tmp"/page_*.html 2>/dev/null | sort -un | \
    awk '{print "https://steamcommunity.com/sharedfiles/filedetails/?id="$1}' > "$all_file" || true
[ -f "$all_file" ] || : > "$all_file"

total=$(wc -l < "$all_file")

if [ "$missing_only" -eq 1 ]; then
    # leading "0" line keeps awk's NR==FNR trick working if the list is empty
    printf '0\n%s\n' "$installed_ids" > "$fetch_tmp/installed.txt"
    awk 'NR==FNR { have[$1]=1; next }
         { id=$0; sub(/.*id=/, "", id); if (!(id in have)) print }' \
        "$fetch_tmp/installed.txt" "$all_file" > "$outfile"
    say ""
    say "Subscribed: $total | already in .acf: $((total - $(wc -l < "$outfile"))) | missing: $(wc -l < "$outfile")"
else
    cp "$all_file" "$outfile"
fi

count=$(wc -l < "$outfile")

if [ "$count" -eq 0 ] && [ "$missing_only" -eq 0 ] || { [ "$total" -eq 0 ] && [ "$missing_only" -eq 1 ]; }; then
    say ""
    say "Session was valid but 0 items were found. Possible causes:"
    say "  - wrong appid ($appid)"
    say "  - you're not actually subscribed to anything for this game"
    say "  - the session cookie is stale (reload steamcommunity.com in Firefox and retry)"
fi

if [ "$copy_mode" -eq 1 ]; then
    if [ "$count" -eq 0 ]; then
        # don't clobber whatever is on the clipboard with nothing
        echo "Nothing to copy (0 links) — clipboard left untouched"
    else
        "${CLIP_CMD[@]}" < "$outfile"
        echo "Copied $count link(s) to clipboard (${CLIP_CMD[0]})"
    fi
else
    echo "Wrote $count link(s) to $outfile"
fi
