#!/bin/bash
# SymbiOS - Generate a Kodi game addon wrapper for a Debian libretro core.
#
# Kodi does not load a libretro core directly: every core needs a gameclient
# addon (game.libretro.<core>) that carries the addon metadata, the controller
# buttonmap and the library name. The Kodi addon mirror ships those wrappers
# for android/osx/windows only (there is no Linux build), and Debian ships
# only the framework addon "game.libretro" plus the bare cores, so the wrapper
# is generated here:
#
#   <kodi home>/.kodi/addons/<addon-id>/addon.xml      rendered from upstream
#   <kodi home>/.kodi/addons/<addon-id>/resources/     buttonmap, settings
#   <kodi home>/.kodi/addons/<addon-id>/<core-so>      symlink to the core
#
# The template (addon.xml.in) and the resources come from the upstream repo
# kodi-game/<addon-id>, the core library from the Debian package (libretro-*).
# Kodi resolves "library_linux" relative to the addon directory
# (CAddon::LibPath = Path() + lib name), so the core has to sit next to
# addon.xml - a symlink keeps a single copy that follows package upgrades.
#
# The addon is generated once and then left alone: Kodi owns the profile, and
# a newer core is picked up through the symlink without regenerating the
# wrapper. To rebuild after an upstream metadata change, remove the addon dir.
#
# Usage:
#   symbios-kodi-game-addon.sh install <addon-id> <core-so> <core-package>
#   symbios-kodi-game-addon.sh list
#
# Output: "install" prints a machine-readable state token as the last line
# (kodi-game-addon-installed / kodi-game-addon-unchanged); "list" prints one
# "<addon-id> <version>" line per generated addon.
# Exit codes: 0 ok (also when the addon already exists), 1 technical error
# (core package not installed, download failed), 2 usage error.

function f_usage {
  cat << EOF
Usage: $(basename "$0") install <addon-id> <core-so> <core-package>
       $(basename "$0") list

Generate a Kodi game addon for a libretro core installed by a Debian package.

Commands:
  install <addon-id> <core-so> <core-package>
                          Generate ~kodi/.kodi/addons/<addon-id> from the
                          upstream template kodi-game/<addon-id> and link the
                          core library of <core-package> into it. Existing
                          addons are kept (kodi-game-addon-unchanged).
                          Example:
                            install game.libretro.gambatte \\
                                    gambatte_libretro.so libretro-gambatte
  list                    Print the generated game addons with their version

Options:
  -h, --help              Show this help and exit

Exit codes:
  0  ok (also when the addon already exists)
  1  core package not installed, download or extraction failed
  2  usage error
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

# Kodi profile and the generated addons; the sources cache lives on the data
# volume so a re-run does not need GitHub again.
g_kodi_home="/home/kodi"
g_addons_dir="${g_kodi_home}/.kodi/addons"
g_src_dir="${g_services_root}/kodi/src"
g_upstream_url="https://codeload.github.com/kodi-game"

# Addon ids are Kodi addon ids (game.libretro.<core>), core names are bare
# shared library file names, packages are Debian package names.
g_addon_re='^game\.libretro\.[a-z0-9][a-z0-9._-]*$'
g_core_re='^[a-z0-9][a-z0-9._-]*\.so$'
g_package_re='^[a-z0-9][a-z0-9.+-]*$'

# Resolve the core library of a Debian package. dpkg -L is used instead of a
# hardcoded multiarch path, so the script works on every architecture.
function f_core_path {
  local f_package="$1"
  local f_core="$2"
  local f_path

  if ! dpkg -s "$f_package" >/dev/null 2>&1
  then
    g_echo_error "core package ${f_package} is not installed"
    return 1
  fi

  f_path=$(dpkg -L "$f_package" 2>/dev/null | grep -m1 "/libretro/${f_core}$")
  if [[ -z $f_path || ! -e $f_path ]]
  then
    g_echo_error "package ${f_package} does not provide libretro/${f_core}"
    return 1
  fi

  printf '%s\n' "$f_path"
}

# Download the upstream template and resources into the cache dir and return
# the directory holding addon.xml.in (codeload names the archive top level
# <addon>-master, stripped while extracting).
function f_fetch_upstream {
  local f_addon="$1"
  local f_dest="${g_src_dir}/${f_addon}"
  local f_tarball="${g_src_dir}/${f_addon}.tar.gz"

  # The template lives in a subdirectory named after the addon id (all current
  # kodi-game repos do); older layouts kept it at the top level. Resolve which
  # one an extraction has, empty when neither.
  local f_template_dir=""
  if [[ -f "${f_dest}/${f_addon}/addon.xml.in" ]]
  then
    f_template_dir="${f_dest}/${f_addon}"
  elif [[ -f "${f_dest}/addon.xml.in" ]]
  then
    f_template_dir="$f_dest"
  fi

  if [[ -n $f_template_dir ]]
  then
    printf '%s\n' "$f_template_dir"
    return 0
  fi

  mkdir -p "$g_src_dir"
  rm -rf "$f_dest" "$f_tarball"

  # codeload serves the branch as a tarball; no git client on the host needed.
  if ! wget -q -O "$f_tarball" "${g_upstream_url}/${f_addon}/tar.gz/refs/heads/master"
  then
    g_echo_error "download of the upstream addon ${f_addon} failed"
    rm -f "$f_tarball"
    return 1
  fi

  # The archive holds a single top-level directory; strip it while extracting.
  mkdir -p "$f_dest"
  if ! tar -xzf "$f_tarball" -C "$f_dest" --strip-components=1
  then
    g_echo_error "extraction of the upstream addon ${f_addon} failed"
    rm -rf "$f_dest" "$f_tarball"
    return 1
  fi
  rm -f "$f_tarball"

  if [[ -f "${f_dest}/${f_addon}/addon.xml.in" ]]
  then
    f_template_dir="${f_dest}/${f_addon}"
  elif [[ -f "${f_dest}/addon.xml.in" ]]
  then
    f_template_dir="$f_dest"
  fi

  if [[ -z $f_template_dir ]]
  then
    g_echo_error "upstream addon ${f_addon} has no addon.xml.in"
    rm -rf "$f_dest"
    return 1
  fi

  printf '%s\n' "$f_template_dir"
}

# Generate the addon directory from the cached template plus the core symlink.
function f_install_addon {
  local f_addon="$1"
  local f_core="$2"
  local f_package="$3"
  local f_addon_dir="${g_addons_dir}/${f_addon}"
  local f_src f_tmp f_lib

  if [[ -f "${f_addon_dir}/addon.xml" ]]
  then
    echo "kodi-game-addon-unchanged"
    return 0
  fi

  f_lib=$(f_core_path "$f_package" "$f_core") || return 1
  f_src=$(f_fetch_upstream "$f_addon") || return 1

  # Build in a staging dir outside the addons dir: a half-written addon dir
  # would look installed to Kodi and to the "already present" check above.
  f_tmp="${g_src_dir}/stage.${f_addon}"
  rm -rf "$f_tmp"
  mkdir -p "$f_tmp"

  # @PLATFORM@ selects the library attribute (library_linux), the library
  # filename is the core the wrapper loads.
  sed -e 's|@PLATFORM@|linux|g' -e "s|@LIBRARY_FILENAME@|${f_core}|g" \
    "${f_src}/addon.xml.in" > "${f_tmp}/addon.xml"
  if [[ -d "${f_src}/resources" ]]
  then
    cp -a "${f_src}/resources" "${f_tmp}/resources"
  fi
  ln -sfn "$f_lib" "${f_tmp}/${f_core}"

  chown -R kodi:kodi "$f_tmp"
  rm -rf "$f_addon_dir"
  mv "$f_tmp" "$f_addon_dir"

  echo "kodi-game-addon-installed"
}

# List the generated game addons with the version from their addon.xml.
function f_list_addons {
  local f_dir f_version

  if [[ ! -d $g_addons_dir ]]
  then
    return 0
  fi

  for f_dir in "${g_addons_dir}"/game.libretro.*
  do
    [[ -f "${f_dir}/addon.xml" ]] || continue
    # The addon tag's version attribute is indented; the xml declaration on
    # line one also carries a version="..." and must not match.
    f_version=$(grep -oE '^[[:space:]]+version="[^"]*"' "${f_dir}/addon.xml" | head -n1 | cut -d'"' -f2)
    printf '%s %s\n' "$(basename "$f_dir")" "${f_version:-unknown}"
  done
}

case "${1:-}" in
  install)
    if [[ $# -ne 4 ]]
    then
      f_usage >&2
      exit 2
    fi
    if [[ ! "${2}" =~ $g_addon_re ]]
    then
      g_echo_error "not a Kodi game addon id: ${2}"
      exit 2
    fi
    if [[ ! "${3}" =~ $g_core_re ]]
    then
      g_echo_error "not a libretro core library name: ${3}"
      exit 2
    fi
    if [[ ! "${4}" =~ $g_package_re ]]
    then
      g_echo_error "not a Debian package name: ${4}"
      exit 2
    fi
    f_install_addon "${2}" "${3}" "${4}" || exit 1
    ;;
  list)
    f_list_addons
    ;;
  *)
    f_usage >&2
    exit 2
    ;;
esac
