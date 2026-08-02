# Shared .env loading for this mod's scripts. Sourced, not executed.
#
# The file is parsed line by line rather than sourced, deliberately: a ROM
# path routinely contains spaces, and `. .env` would split it (and would
# execute anything else in there). Nothing in .env is ever run as shell.
#
# Real environment variables win, so a one-off override on the command line
# beats the file.

load_env() {
  local file="$1"
  [ -f "$file" ] || return 0
  echo "  reading $file"
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    # only well-formed shell names; a malformed line is skipped rather than
    # eval'd, since these values reach the environment
    case "$key" in
      [A-Za-z_]*) ;;
      *) continue ;;
    esac
    case "$key" in
      *[!A-Za-z0-9_]*) continue ;;
    esac
    # strip surrounding quotes if the user added them
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    if [ -z "$(eval "printf '%s' \"\${$key:-}\"" 2>/dev/null)" ]; then
      export "$key=$value"
    fi
  done < "$file"
}

# Which game a ROM actually is, by SHA-1. Empty when it cannot be told.
rom_version_of() {
  local path="$1"
  [ -f "$path" ] || return 0
  command -v shasum >/dev/null 2>&1 || return 0
  case "$(shasum -a 1 "$path" | cut -d' ' -f1)" in
    ea9bcae617fdf159b045185467ae58b2e4a48b9a) echo red ;;
    d7037c83e1ae5b39bde3c30787637ba1d4c48ce2) echo blue ;;
    cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1) echo yellow ;;
    *) echo unknown ;;
  esac
}

# Report on ROM_PATH / ROM_VERSION. Returns non-zero only when they disagree,
# which is the case worth stopping for -- the importer would reject the file
# partway through with a bare SHA-1 mismatch.
check_rom_config() {
  [ -n "${ROM_PATH:-}" ] || return 0
  if [ ! -f "$ROM_PATH" ]; then
    echo "  note: ROM_PATH does not exist ($ROM_PATH)"
    return 0
  fi
  local actual
  actual="$(rom_version_of "$ROM_PATH")"
  case "$actual" in
    '') return 0 ;;
    unknown)
      echo "  note: ROM_PATH is not a canonical US Red/Blue/Yellow ROM"
      return 0 ;;
  esac
  if [ "$actual" != "${ROM_VERSION:-red}" ]; then
    echo "  !! ROM_VERSION says ${ROM_VERSION:-red} but that file is $actual" >&2
    return 1
  fi
  echo "  rom: $actual (verified)"
  return 0
}
