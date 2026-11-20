#!/usr/bin/env bash
#
# make_mac_windows.sh
#
# This is to make a Mac actually user friendly for people on a standard
# Windows (ANSI PC) keyboard. It makes a fresh macOS install behave like
# Windows: Ctrl+C/V/X, Alt+Tab, Home/End, PrintScreen, Ctrl+click,
# Ctrl+scroll zoom, and so on.
#
#   ./make_mac_windows.sh            apply everything
#   ./make_mac_windows.sh --dry-run  show what would change, touch nothing
#
# What it touches:
#   1. Homebrew                   installed if missing
#   2. Karabiner-Elements         installed if missing (the key remapper)
#   3. ~/.config/karabiner/       the remapping rules + enables your mouse
#   4. Firefox user.js            Ctrl+scroll zooms the page
#   5. ~/.zshrc                   Home/End work at the shell prompt
#
# This file is the source of truth and the flow is one-way: edit the shortcuts
# here, run the script, the machine matches. Nothing ever reads settings back
# out of the machine -- so if you change a rule in the Karabiner UI, the next
# run will overwrite it. Make the change here instead.
#
# Idempotent: a run that would change nothing writes nothing. Each step
# compares desired state against actual and skips if they already agree, so
# re-running does not accumulate backups or duplicate lines in config files.
#
# Layout: helpers, then one function per step, then main(), then the rules
# data at the very bottom. main "$@" is the last line, so every function --
# including the data function -- is defined before anything runs.
#
set -euo pipefail

# ===========================================================================
# Helpers
# ===========================================================================

DRY_RUN=0
STAMP=""   # one timestamp per run, so a single run means one backup suffix

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
skip() { printf '    %s\n' "$*"; }
run()  { if (( DRY_RUN )); then printf '    would run: %s\n' "$*"; else eval "$@"; fi; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo "This script is macOS-only."; exit 1; }
}

# ===========================================================================
# Step 1 -- Homebrew
#   Only needed to install Karabiner. An existing install is left alone.
# ===========================================================================
install_homebrew() {
  info "Homebrew"
  if command -v brew >/dev/null 2>&1; then
    skip "already installed ($(brew --version | head -1))"
    return
  fi
  run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  # A fresh install is not on PATH in this shell yet. Apple Silicon puts brew
  # under /opt/homebrew, Intel under /usr/local.
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && eval "$("$p" shellenv)" && break
  done
}

# ===========================================================================
# Step 2 -- Karabiner-Elements
#   This is what actually rewrites keystrokes. It ships a system driver, so
#   first launch needs manual approval -- see print_manual_steps below.
# ===========================================================================
install_karabiner() {
  info "Karabiner-Elements"
  if [[ -d /Applications/Karabiner-Elements.app ]]; then
    skip "already installed"
  else
    run "brew install --cask karabiner-elements"
  fi
}

# The settings window rewrites karabiner.json from its own in-memory state, so
# it MUST be closed before we edit the file or the edit is silently lost.
# Quitting the settings UI does not stop the remapping daemon.
close_karabiner_settings() {
  pgrep -x "Karabiner-Elements" >/dev/null 2>&1 || return 0
  info "Closing Karabiner-Elements settings window (it would overwrite our edits)"
  run "osascript -e 'quit app \"Karabiner-Elements\"' || true"
  sleep 1
}

# ===========================================================================
# Step 3 -- Karabiner rules
#
#   The ruleset comes from karabiner_rules_json() at the bottom of this file.
#   To keep that blob reviewable, the app lists rules are scoped to (terminals,
#   remote-desktop clients, browsers...) are declared once under
#   "condition_sets" and referenced by name; the Python below expands them into
#   the shape Karabiner wants. That de-duplication takes it from ~75KB to ~33KB.
#
#   What the rules do, in short:
#     - Ctrl+C/V/X/Z/Y/S/N/W/F       the usual Windows editing shortcuts
#     - Ctrl+A                       select all
#     - Ctrl+T / Ctrl+F              new tab / find, including in terminals
#     - Ctrl+arrows                  jump word;  Ctrl+Shift+arrows select word
#     - Ctrl+Backspace/Delete        delete a whole word
#     - Home/End (+Shift, +Ctrl)     line / document navigation and selection
#     - Alt+Tab / Alt+`              switch application / window
#     - Alt+F4                       quit application
#     - Ctrl+Plus/Minus/0            zoom in / out / reset
#     - PrintScreen                  region grab (Shift+ = full screen to clipboard)
#     - Ctrl+click                   new tab in browsers, multi-select in Finder
#     - Browsers                     Ctrl+L/R, Ctrl+Shift+P/N private window,
#                                    Ctrl+Enter completes .com (Firefox)
#     - Finder                       Enter opens, F2 renames, Backspace goes up
#
#   Terminals (Terminal.app, iTerm2, ...) follow Windows Terminal: plain Ctrl+
#   keys the shell needs stay with the shell, so Ctrl+C is still an interrupt
#   and Ctrl+W still deletes a word; copy/paste/close move to Ctrl+Shift+C/V/W.
#
#   Remote-desktop and VM apps (Parallels, VMware, Microsoft RDP...) are
#   excluded everywhere: the Windows machine inside them already understands
#   Ctrl+C natively, and remapping it would break that.
#
#   Conductor is treated as a GUI app with a terminal attached, not as a
#   terminal: Ctrl+C/V/X/Z copy and undo there, and Ctrl+Shift+C sends a real
#   interrupt to its terminal panes. Karabiner only sees the frontmost app,
#   so it cannot tell the chat box from a terminal pane -- the chat box wins.
# ===========================================================================
apply_karabiner_rules() {
  info "Karabiner rules"

  local payload
  payload="$(mktemp)"
  karabiner_rules_json > "$payload"

  DRY_RUN="$DRY_RUN" STAMP="$STAMP" python3 - "$payload" <<'PYTHON'
import json, os, shutil, sys

dry   = os.environ.get("DRY_RUN") == "1"
stamp = os.environ["STAMP"]
cfg_p = os.path.expanduser("~/.config/karabiner/karabiner.json")

payload = json.load(open(sys.argv[1]))
sets    = payload["condition_sets"]
rules   = payload["rules"]

# Expand {"type": ..., "apps": "<name>"} back into a real Karabiner condition
# carrying the full bundle-identifier list.
for rule in rules:
    for man in rule["manipulators"]:
        for cond in man.get("conditions", []):
            if "apps" in cond:
                cond["bundle_identifiers"] = sets[cond.pop("apps")]

if os.path.exists(cfg_p):
    cfg = json.load(open(cfg_p))
    profiles = cfg.get("profiles") or []
    if not profiles:
        profiles = [{"name": "Default profile", "selected": True}]
        cfg["profiles"] = profiles
    # Target whichever profile is selected in the UI, not blindly the first.
    idx = next((i for i, p in enumerate(profiles) if p.get("selected")), 0)
    target = profiles[idx]
    old = len(target.get("complex_modifications", {}).get("rules", []))
    action = "replaced %d rule(s) with %d in profile %r" % (old, len(rules), target.get("name"))
else:
    # Fresh machine: Karabiner has never run. Write a minimal valid config and
    # let the app fill in its own defaults on first launch.
    cfg = {"profiles": [{"name": "Default profile", "selected": True}]}
    target = cfg["profiles"][0]
    action = "created new config with %d rules" % len(rules)

# Replace ONLY the rules. Device settings, simple modifications and
# function-key config the user may have set are preserved.
current = target.get("complex_modifications", {}).get("rules")
target.setdefault("complex_modifications", {})["rules"] = rules

# Idempotence: if the machine already matches, write nothing at all. Without
# this every run would leave another backup file behind.
if current == rules:
    print("    already up to date (%d rules)" % len(rules))
elif dry:
    print("    would have " + action)
else:
    os.makedirs(os.path.dirname(cfg_p), exist_ok=True)
    if os.path.exists(cfg_p):
        backup = "%s.%s.bak" % (cfg_p, stamp)
        shutil.copy2(cfg_p, backup)
        print("    backup -> " + backup)
    with open(cfg_p, "w") as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
        f.write("\n")
    print("    " + action)
PYTHON

  rm -f "$payload"
}

# ===========================================================================
# Step 3b -- let Karabiner modify the mouse
#
#   Karabiner modifies keyboards out of the box but IGNORES pointing devices
#   unless each one is explicitly enabled. That silently disables every mouse
#   rule: Ctrl+click never becomes Cmd+click, so it stays a macOS
#   secondary-click and browsers never see a new-tab request.
#
#   Device entries are keyed on vendor/product IDs, which differ per machine
#   and per mouse -- so this discovers whatever is actually plugged in rather
#   than hard-coding IDs that would be wrong on the next Mac.
# ===========================================================================
enable_pointing_devices() {
  info "Mouse devices"
  DRY_RUN="$DRY_RUN" STAMP="$STAMP" python3 <<'PYTHON'
import json, os, re, shutil, subprocess

dry   = os.environ.get("DRY_RUN") == "1"
stamp = os.environ["STAMP"]
cfg_p = os.path.expanduser("~/.config/karabiner/karabiner.json")

if not os.path.exists(cfg_p):
    print("    no config yet, skipping")
    raise SystemExit(0)

# Enumerate real pointing devices. Usage page 1 (generic desktop) with usage
# 1 (pointer) or 2 (mouse) is the HID way of saying "this is a mouse".
txt = subprocess.run(["ioreg", "-c", "IOHIDDevice", "-r", "-d", "1"],
                     capture_output=True, text=True).stdout
found = set()
for block in re.split(r"\n\s*\+\-o ", txt):
    def g(key):
        m = re.search(r'"%s" = (\S+)' % key, block)
        return m.group(1).strip('"') if m else None
    if g("PrimaryUsagePage") == "1" and g("PrimaryUsage") in ("1", "2"):
        vendor, product = g("VendorID"), g("ProductID")
        # 5824 is Karabiner's own virtual device -- never manage that one.
        if vendor and product and vendor != "5824":
            found.add((int(vendor), int(product)))

if not found:
    print("    no pointing devices detected")
    raise SystemExit(0)

cfg = json.load(open(cfg_p))
profiles = cfg["profiles"]
profile = next((p for p in profiles if p.get("selected")), profiles[0])
devices = profile.setdefault("devices", [])

added = []
for vendor, product in sorted(found):
    entry = next((d for d in devices
                  if d.get("identifiers", {}).get("vendor_id") == vendor
                  and d.get("identifiers", {}).get("product_id") == product
                  and d.get("identifiers", {}).get("is_pointing_device")), None)
    if entry is None:
        devices.append({"identifiers": {"is_pointing_device": True,
                                        "product_id": product,
                                        "vendor_id": vendor},
                        "ignore": False})
        added.append((vendor, product))
    elif entry.get("ignore"):
        entry["ignore"] = False
        added.append((vendor, product))

if not added:
    print("    already enabled (%d pointing device(s))" % len(found))
elif dry:
    for v, p in added:
        print("    would enable vendor=%d product=%d" % (v, p))
else:
    shutil.copy2(cfg_p, "%s.%s.bak" % (cfg_p, stamp))
    with open(cfg_p, "w") as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
        f.write("\n")
    for v, p in added:
        print("    enabled vendor=%d product=%d" % (v, p))
PYTHON
}

# Karabiner ships its own linter -- use it to prove what we wrote is valid.
lint_karabiner_rules() {
  local kcli="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
  [[ -x "$kcli" && $DRY_RUN -eq 0 ]] || return 0
  local lint
  lint="$(mktemp)"
  python3 -c '
import json, os, sys
cfg = json.load(open(os.path.expanduser("~/.config/karabiner/karabiner.json")))
prof = next((p for p in cfg["profiles"] if p.get("selected")), cfg["profiles"][0])
json.dump({"title": "check", "rules": prof["complex_modifications"]["rules"]},
          open(sys.argv[1], "w"))
' "$lint"
  "$kcli" --lint-complex-modifications "$lint" >/dev/null && skip "ruleset validated by karabiner_cli"
  rm -f "$lint"
}

# ===========================================================================
# Step 4 -- Firefox: Ctrl+scroll zooms the page
#
#   Karabiner cannot do this -- it has no scroll trigger, only key and mouse
#   button events. Firefox exposes the behaviour as a pref instead. It goes in
#   user.js rather than prefs.js because Firefox rewrites prefs.js on exit and
#   would discard the change; user.js is re-applied at every startup.
# ===========================================================================
configure_firefox() {
  info "Firefox preferences"
  local dir="$HOME/Library/Application Support/Firefox/Profiles"
  if [[ ! -d "$dir" ]]; then
    skip "Firefox not set up yet -- re-run this script after its first launch"
    return
  fi

  local found=0 prof userjs
  for prof in "$dir"/*/; do
    [[ -d "$prof" ]] || continue
    found=1
    userjs="${prof}user.js"
    if [[ -f "$userjs" ]] && grep -q "mousewheel.with_control.action" "$userjs"; then
      skip "$(basename "$prof"): already set"
    elif (( DRY_RUN )); then
      skip "would add mousewheel pref to $(basename "$prof")"
    else
      # Append, never overwrite -- other tooling (e.g. enterprise certificate
      # settings pushed by IT) also lives in user.js.
      [[ -f "$userjs" ]] && cp "$userjs" "$userjs.$STAMP.bak"
      [[ -s "$userjs" ]] && echo "" >> "$userjs"
      cat >> "$userjs" <<'EOF'
// Ctrl+scroll zooms the page, like Windows. 3 = zoom contents.
user_pref("mousewheel.with_control.action", 3);
EOF
      skip "$(basename "$prof"): added"
    fi
  done
  (( found )) || skip "no profiles found"
}

# ===========================================================================
# Step 5 -- zsh: make Home/End work at the shell prompt
#
#   Terminals disagree about which escape sequence Home/End emit, and common
#   zsh setups bind only the application-cursor-mode form. Anything sending
#   the normal-mode or vt220 form silently does nothing, so bind them all.
#   Karabiner deliberately leaves Home/End untouched in real terminals so
#   these sequences can reach the shell in the first place.
# ===========================================================================
configure_zsh() {
  info "zsh key bindings"
  local zshrc="$HOME/.zshrc"
  local marker="# --- make-mac-windows: Home/End ---"

  # Match the marker OR an already-present binding, so running this on a
  # machine that was set up by hand does not append a duplicate block.
  if [[ -f "$zshrc" ]] && grep -qE '^# --- make-mac-windows: Home/End ---|^bindkey +"\^\[\[H"' "$zshrc"; then
    skip "already present"
    return
  fi
  if (( DRY_RUN )); then
    skip "would append Home/End bindkeys to ~/.zshrc"
    return
  fi

  [[ -f "$zshrc" ]] && cp "$zshrc" "$zshrc.$STAMP.bak"
  cat >> "$zshrc" <<EOF

$marker
bindkey "^[[H"  beginning-of-line   # xterm normal mode
bindkey "^[OH"  beginning-of-line   # xterm application mode
bindkey "^[[1~" beginning-of-line   # vt220
bindkey "^[[7~" beginning-of-line   # rxvt
bindkey "^[[F"  end-of-line
bindkey "^[OF"  end-of-line
bindkey "^[[4~" end-of-line
bindkey "^[[8~" end-of-line
EOF
  skip "appended to ~/.zshrc"
}

# ===========================================================================
# Step 6 -- What still needs a human
# ===========================================================================
print_manual_steps() {
  cat <<'EOF'

Done. Three things cannot be scripted:

  1. Open Karabiner-Elements once and approve its driver.
     System Settings > Privacy & Security -- allow the "org.pqrs" system
     extension, then grant Input Monitoring. Nothing remaps until you do.

  2. Restart Firefox so user.js is read.

  3. Open a new terminal tab so .zshrc is re-sourced.

Optional: `brew install --cask alt-tab` gives a true Windows Alt+Tab that
lists every window and restores minimized ones, which macOS's own Cmd+Tab
will not do. It binds Option+Tab itself, so remove the Alt+Tab rule from
Karabiner if you install it.
EOF
}

# ===========================================================================
# main
# ===========================================================================
main() {
  STAMP="$(date +%Y%m%d-%H%M%S)"

  case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "")        ;;
    *)         echo "unknown option: $1"; echo "usage: $0 [--dry-run]"; exit 1 ;;
  esac

  require_macos
  (( DRY_RUN )) && warn "DRY RUN -- no changes will be written"

  install_homebrew
  install_karabiner
  close_karabiner_settings
  apply_karabiner_rules
  enable_pointing_devices
  lint_karabiner_rules
  configure_firefox
  configure_zsh
  print_manual_steps
}

# ===========================================================================
# Data -- the Karabiner ruleset
#
#   Kept at the bottom and behind a function so the executable logic above
#   stays readable. To change a shortcut, edit it here and re-run the script.
#
#   "condition_sets" declares each app list once so the rules can reference it
#   by name -- the terminal group alone is used by eleven rules, so editing it
#   in one place is the difference between a one-line change and eleven. The
#   names are positional ("excl_1", "only_2"); grep a rule's "apps" value to
#   see which list it uses.
# ===========================================================================
karabiner_rules_json() {
  cat <<'KARABINER_RULES_JSON'
{
 "condition_sets": {
  "only_1": [
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$",
   "^com\\.conductor\\.app$"
  ],
  "excl_1": [
   "^com\\.microsoft\\.rdc$",
   "^com\\.microsoft\\.rdc\\.mac$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^com\\.microsoft\\.rdc\\.osx\\.beta$",
   "^net\\.sf\\.cord$",
   "^com\\.thinomenon\\.RemoteDesktopConnection$",
   "^com\\.itap-mobile\\.qmote$",
   "^com\\.nulana\\.remotixmac$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer\\.web$",
   "^com\\.teamviewer\\.TeamViewer$",
   "^com\\.vmware\\.horizon$",
   "^com\\.2X\\.Client\\.Mac$",
   "^com\\.vmware\\.fusion$",
   "^com\\.vmware\\.horizon$",
   "^com\\.vmware\\.view$",
   "^com\\.parallels\\.desktop$",
   "^com\\.parallels\\.vm$",
   "^com\\.parallels\\.desktop\\.console$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.citrix\\.XenAppViewer$",
   "^com\\.vmware\\.proxyApp\\.",
   "^com\\.parallels\\.winapp\\.",
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyperterm$",
   "^co\\.zeit\\.hyper$",
   "^io\\.alacritty$",
   "^net\\.kovidgoyal\\.kitty$",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$",
   "^com\\.conductor\\.app$"
  ],
  "excl_2": [
   "^com\\.microsoft\\.rdc$",
   "^com\\.microsoft\\.rdc\\.mac$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^com\\.microsoft\\.rdc\\.osx\\.beta$",
   "^net\\.sf\\.cord$",
   "^com\\.thinomenon\\.RemoteDesktopConnection$",
   "^com\\.itap-mobile\\.qmote$",
   "^com\\.nulana\\.remotixmac$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer\\.web$",
   "^com\\.teamviewer\\.TeamViewer$",
   "^com\\.vmware\\.horizon$",
   "^com\\.2X\\.Client\\.Mac$",
   "^com\\.vmware\\.fusion$",
   "^com\\.vmware\\.horizon$",
   "^com\\.vmware\\.view$",
   "^com\\.parallels\\.desktop$",
   "^com\\.parallels\\.vm$",
   "^com\\.parallels\\.desktop\\.console$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.citrix\\.XenAppViewer$",
   "^com\\.vmware\\.proxyApp\\.",
   "^com\\.parallels\\.winapp\\.",
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyperterm$",
   "^co\\.zeit\\.hyper$",
   "^io\\.alacritty$",
   "^net\\.kovidgoyal\\.kitty$",
   "^tv\\.parsec\\.www$"
  ],
  "only_2": [
   "^com\\.google\\.VSCode$"
  ],
  "only_3": [
   "^com\\.google\\.Chrome$",
   "^com\\.microsoft\\.edgemac$"
  ],
  "excl_3": [
   "^com\\.microsoft\\.rdc$",
   "^com\\.microsoft\\.rdc\\.mac$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^com\\.microsoft\\.rdc\\.osx\\.beta$",
   "^net\\.sf\\.cord$",
   "^com\\.thinomenon\\.RemoteDesktopConnection$",
   "^com\\.itap-mobile\\.qmote$",
   "^com\\.nulana\\.remotixmac$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer\\.web$",
   "^com\\.teamviewer\\.TeamViewer$",
   "^com\\.vmware\\.horizon$",
   "^com\\.2X\\.Client\\.Mac$",
   "^com\\.vmware\\.fusion$",
   "^com\\.vmware\\.horizon$",
   "^com\\.vmware\\.view$",
   "^com\\.parallels\\.desktop$",
   "^com\\.parallels\\.vm$",
   "^com\\.parallels\\.desktop\\.console$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.citrix\\.XenAppViewer$",
   "^com\\.vmware\\.proxyApp\\.",
   "^com\\.parallels\\.winapp\\.",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$",
   "^com\\.conductor\\.app$"
  ],
  "excl_4": [
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyper$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$"
  ],
  "excl_5": [
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyper$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^tv\\.parsec\\.www$"
  ],
  "excl_6": [
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyper$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$",
   "^com\\.conductor\\.app$"
  ],
  "only_4": [
   "^org\\.mozilla\\.firefox$",
   "^org\\.mozilla\\.firefoxdeveloperedition$",
   "^org\\.mozilla\\.nightly$",
   "^com\\.microsoft\\.edgemac$",
   "^com\\.google\\.Chrome$",
   "^com\\.brave\\.Browser$",
   "^com\\.apple\\.Safari$"
  ],
  "excl_7": [
   "^com\\.microsoft\\.rdc$",
   "^com\\.microsoft\\.rdc\\.mac$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^com\\.microsoft\\.rdc\\.osx\\.beta$",
   "^net\\.sf\\.cord$",
   "^com\\.thinomenon\\.RemoteDesktopConnection$",
   "^com\\.itap-mobile\\.qmote$",
   "^com\\.nulana\\.remotixmac$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer\\.web$",
   "^com\\.teamviewer\\.TeamViewer$",
   "^com\\.vmware\\.horizon$",
   "^com\\.2X\\.Client\\.Mac$",
   "^com\\.vmware\\.fusion$",
   "^com\\.vmware\\.horizon$",
   "^com\\.vmware\\.view$",
   "^com\\.parallels\\.desktop$",
   "^com\\.parallels\\.vm$",
   "^com\\.parallels\\.desktop\\.console$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.citrix\\.XenAppViewer$",
   "^com\\.vmware\\.proxyApp\\.",
   "^com\\.parallels\\.winapp\\.",
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyperterm$",
   "^co\\.zeit\\.hyper$",
   "^io\\.alacritty$",
   "^net\\.kovidgoyal\\.kitty$",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$"
  ],
  "excl_8": [
   "^com\\.microsoft\\.rdc$",
   "^com\\.microsoft\\.rdc\\.",
   "^net\\.sf\\.cord$",
   "^com\\.thinomenon\\.RemoteDesktopConnection$",
   "^com\\.itap-mobile\\.qmote$",
   "^com\\.nulana\\.remotixmac$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer\\.",
   "^com\\.teamviewer\\.TeamViewer$",
   "^com\\.vmware\\.horizon$",
   "^com\\.2X\\.Client\\.Mac$",
   "^com\\.vmware\\.fusion$",
   "^com\\.vmware\\.horizon$",
   "^com\\.vmware\\.view$",
   "^com\\.parallels\\.desktop$",
   "^com\\.parallels\\.vm$",
   "^com\\.parallels\\.desktop\\.console$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.citrix\\.XenAppViewer$",
   "^com\\.vmware\\.proxyApp\\.",
   "^com\\.parallels\\.winapp\\.",
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyperterm$",
   "^co\\.zeit\\.hyper$",
   "^io\\.alacritty$",
   "^net\\.kovidgoyal\\.kitty$",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$",
   "^com\\.conductor\\.app$"
  ],
  "only_5": [
   "^com.apple.finder"
  ],
  "excl_9": [
   "^com\\.microsoft\\.rdc$",
   "^com\\.microsoft\\.rdc\\.mac$",
   "^com\\.microsoft\\.rdc\\.macos$",
   "^com\\.microsoft\\.rdc\\.osx\\.beta$",
   "^net\\.sf\\.cord$",
   "^com\\.thinomenon\\.RemoteDesktopConnection$",
   "^com\\.itap-mobile\\.qmote$",
   "^com\\.nulana\\.remotixmac$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer$",
   "^com\\.p5sys\\.jump\\.mac\\.viewer\\.web$",
   "^com\\.teamviewer\\.TeamViewer$",
   "^com\\.vmware\\.horizon$",
   "^com\\.2X\\.Client\\.Mac$",
   "^com\\.vmware\\.fusion$",
   "^com\\.vmware\\.horizon$",
   "^com\\.vmware\\.view$",
   "^com\\.parallels\\.desktop$",
   "^com\\.parallels\\.vm$",
   "^com\\.parallels\\.desktop\\.console$",
   "^org\\.virtualbox\\.app\\.VirtualBoxVM$",
   "^com\\.citrix\\.XenAppViewer$",
   "^com\\.vmware\\.proxyApp\\.",
   "^com\\.parallels\\.winapp\\.",
   "^org\\.macports\\.X11$",
   "^co\\.zeit\\.hyperterm$",
   "^co\\.zeit\\.hyper$",
   "^io\\.alacritty$",
   "^net\\.kovidgoyal\\.kitty$",
   "^tv\\.parsec\\.www$",
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$"
  ],
  "only_6": [
   "^com\\.conductor\\.app$"
  ],
  "only_7": [
   "^org\\.mozilla\\.firefox$",
   "^org\\.mozilla\\.firefoxdeveloperedition$",
   "^org\\.mozilla\\.nightly$"
  ],
  "only_8": [
   "^com\\.apple\\.Terminal$",
   "^com\\.googlecode\\.iterm2$",
   "^com\\.github\\.wez\\.wezterm$",
   "^org\\.alacritty$",
   "^com\\.mitchellh\\.ghostty$",
   "^dev\\.warp\\.Warp-Stable$"
  ]
 },
 "rules": [
  {
   "description": "Conductor: Ctrl+Shift+C => real Ctrl+C (SIGINT, since Ctrl+C now copies)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_6"
      }
     ],
     "from": {
      "key_code": "c",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "c",
       "modifiers": [
        "left_control"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Terminal: Ctrl+Left/Right => Esc+b / Esc+f (jump word)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_8"
      }
     ],
     "from": {
      "key_code": "left_arrow",
      "modifiers": {
       "mandatory": [
        "control"
       ]
      }
     },
     "to": [
      {
       "key_code": "escape"
      },
      {
       "key_code": "b"
      }
     ],
     "type": "basic"
    },
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_8"
      }
     ],
     "from": {
      "key_code": "right_arrow",
      "modifiers": {
       "mandatory": [
        "control"
       ]
      }
     },
     "to": [
      {
       "key_code": "escape"
      },
      {
       "key_code": "f"
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Terminal: Ctrl+Shift+C/V/W/A => Cmd+C/V/W/A (plain Ctrl+ stays with the shell)",
   "manipulators": [
    {
     "type": "basic",
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_1"
      }
     ],
     "from": {
      "key_code": "c",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "c",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_1"
      }
     ],
     "from": {
      "key_code": "v",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "v",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_1"
      }
     ],
     "from": {
      "key_code": "w",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "w",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_1"
      }
     ],
     "from": {
      "key_code": "a",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "a",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    }
   ]
  },
  {
   "description": "PrintScreen => Cmd+Shift+4 (region grab); Shift+PrintScreen => whole screen to clipboard",
   "manipulators": [
    {
     "type": "basic",
     "from": {
      "key_code": "print_screen",
      "modifiers": {
       "mandatory": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "3",
       "modifiers": [
        "left_command",
        "left_control",
        "left_shift"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "print_screen"
     },
     "to": [
      {
       "key_code": "4",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "f13",
      "modifiers": {
       "mandatory": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "3",
       "modifiers": [
        "left_command",
        "left_control",
        "left_shift"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "f13"
     },
     "to": [
      {
       "key_code": "4",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ]
    }
   ]
  },
  {
   "description": "Alt+Tab => Cmd+Tab (switch app), Alt+` => Cmd+` (switch window); Shift cycles backwards",
   "manipulators": [
    {
     "type": "basic",
     "from": {
      "key_code": "tab",
      "modifiers": {
       "mandatory": [
        "option",
        "shift"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "tab",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "tab",
      "modifiers": {
       "mandatory": [
        "option"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "tab",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "grave_accent_and_tilde",
      "modifiers": {
       "mandatory": [
        "option",
        "shift"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "grave_accent_and_tilde",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "grave_accent_and_tilde",
      "modifiers": {
       "mandatory": [
        "option"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "grave_accent_and_tilde",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    }
   ]
  },
  {
   "description": "Ctrl+Plus/Minus/0 => Cmd+Plus/Minus/0 (zoom in / out / reset)",
   "manipulators": [
    {
     "type": "basic",
     "from": {
      "key_code": "equal_sign",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "equal_sign",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "hyphen",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "hyphen",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    },
    {
     "type": "basic",
     "from": {
      "key_code": "0",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "0",
       "modifiers": [
        "left_command"
       ]
      }
     ]
    }
   ]
  },
  {
   "description": "Ctrl+C, Ctrl+V, Ctrl+X => Cmd+C (Copy), Cmd+V (Paste), Cmd+X (Cut)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_9"
      }
     ],
     "from": {
      "key_code": "c",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "c",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    },
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_9"
      }
     ],
     "from": {
      "key_code": "v",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "v",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    },
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_9"
      }
     ],
     "from": {
      "key_code": "x",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "x",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Z => Cmd+Z (Undo)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_9"
      }
     ],
     "from": {
      "key_code": "z",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "z",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Y => Cmd+Shift+Z (Redo)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_9"
      }
     ],
     "from": {
      "key_code": "y",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "z",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+A => Cmd+A (Select all)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_2"
      }
     ],
     "from": {
      "key_code": "a",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "a",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+S => Cmd+S (Save)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_1"
      }
     ],
     "from": {
      "key_code": "s",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "s",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+N => Cmd+N (New)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_1"
      }
     ],
     "from": {
      "key_code": "n",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "n",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+F => Cmd+F (Find)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_2"
      }
     ],
     "from": {
      "key_code": "f",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "f",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+H => Cmd+Option+F (Find and Replace - Only in Code)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_2"
      }
     ],
     "from": {
      "key_code": "h",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "f",
       "modifiers": [
        "left_command",
        "left_option"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+H => Cmd+Y (History - Only in Chrome)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_3"
      }
     ],
     "from": {
      "key_code": "h",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "y",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+J => Cmd+Option+L (Open Downloads - Only in Code)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_3"
      }
     ],
     "from": {
      "key_code": "j",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "l",
       "modifiers": [
        "left_command",
        "left_option"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+W => Cmd+W (Close)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_1"
      }
     ],
     "from": {
      "key_code": "w",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "w",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Alt+F4 => Cmd+Q (Exit application)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_3"
      }
     ],
     "from": {
      "key_code": "f4",
      "modifiers": {
       "mandatory": [
        "option"
       ]
      }
     },
     "to": [
      {
       "key_code": "q",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Home => Cmd+Left arrow (Move cursor to beginning of line)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_4"
      }
     ],
     "from": {
      "key_code": "home"
     },
     "to": [
      {
       "key_code": "left_arrow",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Shift+Home => Cmd+Shift+Left arrow (Move cursor to beginning of line with selection)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_4"
      }
     ],
     "from": {
      "key_code": "home",
      "modifiers": {
       "mandatory": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "left_arrow",
       "modifiers": [
        "command",
        "shift"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Home, Ctrl+Shift+Home => Cmd+Up arrow, Cmd+Shift+Up arrow (Move cursor to beginning of file with and without selection)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_4"
      }
     ],
     "from": {
      "key_code": "home",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "up_arrow",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "End => Cmd+Right arrow (Move cursor to end of line)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_4"
      }
     ],
     "from": {
      "key_code": "end"
     },
     "to": [
      {
       "key_code": "right_arrow",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Shift+End => Cmd+Shift+Right arrow (Move cursor to end of line with selection)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_4"
      }
     ],
     "from": {
      "key_code": "end",
      "modifiers": {
       "mandatory": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "right_arrow",
       "modifiers": [
        "command",
        "shift"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+End, Ctrl+Shift+End => Cmd+down arrow, Cmd+Shift+down arrow (Move cursor to end of file with and without selection)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_4"
      }
     ],
     "from": {
      "key_code": "end",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "down_arrow",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+T => Cmd+T (New tab)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_5"
      }
     ],
     "from": {
      "key_code": "t",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "t",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+B => Cmd+B (Bold)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_6"
      }
     ],
     "from": {
      "key_code": "b",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "b",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+I => Cmd+I (Italic)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_6"
      }
     ],
     "from": {
      "key_code": "i",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "i",
       "modifiers": [
        "command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+L => Cmd+L (Open url location) (Only in browsers)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_4"
      }
     ],
     "from": {
      "key_code": "l",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "l",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+R => Cmd+R (Reload) (Only in browsers)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_4"
      }
     ],
     "from": {
      "key_code": "r",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "r",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Shift+P => Cmd+Shift+P (New private window) (Only in browsers)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_4"
      }
     ],
     "from": {
      "key_code": "p",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "p",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Shift+N => Cmd+Shift+N (New incognito window) (Only in browsers)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_4"
      }
     ],
     "from": {
      "key_code": "n",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "n",
       "modifiers": [
        "left_command",
        "left_shift"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Enter => Cmd+Enter (complete .com address) (Only in Firefox)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_7"
      }
     ],
     "from": {
      "key_code": "return_or_enter",
      "modifiers": {
       "mandatory": [
        "control"
       ]
      }
     },
     "to": [
      {
       "key_code": "return_or_enter",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "F5 => Cmd+r (Reload)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_1"
      }
     ],
     "from": {
      "key_code": "f5",
      "modifiers": {
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "r",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+(Shift)+Right/left arrow => Alt+(Shift)+Right/left arrow (Move cursor one word with selection and without selection)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_7"
      }
     ],
     "from": {
      "key_code": "left_arrow",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "left_arrow",
       "modifiers": [
        "left_option"
       ]
      }
     ],
     "type": "basic"
    },
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_7"
      }
     ],
     "from": {
      "key_code": "right_arrow",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "right_arrow",
       "modifiers": [
        "left_option"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Backspace/Delete => Option+(Fn)+Delete (Remove a whole word ahead or behind)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_1"
      }
     ],
     "from": {
      "key_code": "delete_or_backspace",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "delete_or_backspace",
       "modifiers": [
        "left_option"
       ]
      }
     ],
     "type": "basic"
    },
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_1"
      }
     ],
     "from": {
      "key_code": "delete_forward",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "delete_forward",
       "modifiers": [
        "left_option"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Up/down arrow => Up/down arrow (Move cursor up/down)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_8"
      }
     ],
     "from": {
      "key_code": "up_arrow",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "up_arrow"
      }
     ],
     "type": "basic"
    },
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_8"
      }
     ],
     "from": {
      "key_code": "down_arrow",
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "shift"
       ]
      }
     },
     "to": [
      {
       "key_code": "down_arrow",
       "modifiers": []
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Cmd+L => Cmd+Option+Q (Lock Screen)",
   "manipulators": [
    {
     "from": {
      "key_code": "l",
      "modifiers": {
       "mandatory": [
        "command"
       ]
      }
     },
     "to": [
      {
       "key_code": "q",
       "modifiers": [
        "left_control",
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Esc => Open Launchpad",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_3"
      }
     ],
     "from": {
      "key_code": "escape",
      "modifiers": {
       "mandatory": [
        "control"
       ]
      }
     },
     "to": [
      {
       "key_code": "launchpad",
       "modifiers": []
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Shift+Esc => Open Activity Monitor",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_unless",
       "apps": "excl_3"
      }
     ],
     "from": {
      "key_code": "escape",
      "modifiers": {
       "mandatory": [
        "control",
        "shift"
       ]
      }
     },
     "to": [
      {
       "shell_command": "open -a 'Activity Monitor.app'"
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Return => Cmd+o (Open) (Only in Finder)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_5"
      }
     ],
     "from": {
      "key_code": "return_or_enter",
      "modifiers": {
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "o",
       "modifiers": [
        "right_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "F2 => Return (Rename) (Only in Finder)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_5"
      }
     ],
     "from": {
      "key_code": "f2"
     },
     "to": [
      {
       "key_code": "return_or_enter"
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Delete => Cmd+backspace (Delete) (Only in Finder)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_5"
      }
     ],
     "from": {
      "key_code": "delete_forward",
      "modifiers": {
       "optional": [
        "any"
       ]
      }
     },
     "to": [
      {
       "key_code": "delete_or_backspace",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Backspace => Cmd+up (Go back) (Only in Finder)",
   "manipulators": [
    {
     "conditions": [
      {
       "type": "frontmost_application_if",
       "apps": "only_5"
      }
     ],
     "from": {
      "key_code": "delete_or_backspace"
     },
     "to": [
      {
       "key_code": "up_arrow",
       "modifiers": [
        "left_command"
       ]
      }
     ],
     "type": "basic"
    }
   ]
  },
  {
   "description": "Ctrl+Left Click => Cmd+Left Click (select multiple items)",
   "manipulators": [
    {
     "from": {
      "modifiers": {
       "mandatory": [
        "control"
       ],
       "optional": [
        "any"
       ]
      },
      "pointing_button": "button1"
     },
     "to": [
      {
       "modifiers": [
        "left_command"
       ],
       "pointing_button": "button1"
      }
     ],
     "type": "basic"
    }
   ]
  }
 ]
}
KARABINER_RULES_JSON
}

main "$@"
