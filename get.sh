#!/bin/sh
# Ame-FileManager — one-line installer for any Linux distribution (and FreeBSD):
#
#   curl -fsSL https://raw.githubusercontent.com/TatsuyaM2667/ame-Filemanager/main/get.sh | sh
#
# 1. installs the build / runtime packages with your package manager (shows the command, asks
#    for your password through doas or sudo)          — skip with NO_DEPS=1
# 2. gets Odin dev-2026-08 (the version the app is developed with) into
#    ~/.local/share/ame-filemanager/ — official binary on glibc, built from source on musl
# 3. downloads this repository, builds it and installs it into ~/.local (PREFIX=… to change)
#    and makes it the default file manager                — keep yours with NO_DEFAULT=1
# 4. adds the Symbols Nerd Font to ~/.local/share/fonts if no icon font is installed
set -eu

REPO="TatsuyaM2667/ame-Filemanager"
BRANCH="${BRANCH:-main}"
ODIN_TAG="dev-2026-08"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/ame-filemanager"
export PREFIX="${PREFIX:-$HOME/.local}"

say()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

command -v curl >/dev/null 2>&1 || die "curl is needed"
command -v tar  >/dev/null 2>&1 || die "tar is needed"

as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif have doas; then doas "$@"
    elif have sudo; then sudo "$@"
    else die "neither doas nor sudo: run as root, or install the packages yourself and use NO_DEPS=1"
    fi
}

# Shows the command, then runs it as root. Optional sets may fail (a name that differs on
# this release, a repository that isn't enabled): that only costs that feature.
install_pkgs() { # $1 = required|optional, rest = command
    kind=$1; shift
    say "$*"
    if ! as_root "$@"; then
        [ "$kind" = required ] && die "could not install the required packages above"
        warn "some optional packages were not installed (previews, conversion or fonts may be missing)"
    fi
}

OS=$(uname -s)
MUSL=0
if [ "$OS" = Linux ] && { ldd --version 2>&1 | grep -qi musl || [ -e /lib/ld-musl-x86_64.so.1 ] || [ -e /lib/ld-musl-aarch64.so.1 ]; }; then MUSL=1; fi
ID=""
[ -r /etc/os-release ] && ID=$(. /etc/os-release && echo "${ID:-}")

# --- 1. packages -------------------------------------------------------------
if [ -z "${NO_DEPS:-}" ]; then
    if [ "$OS" = FreeBSD ]; then
        install_pkgs required pkg install -y odin wayland libxkbcommon freetype2 libarchive
        install_pkgs optional pkg install -y ffmpeg xdg-utils noto-sans-cjk nerd-fonts
    elif have apk && [ "$ID" = chimera ]; then
        install_pkgs required apk add wayland-devel libxkbcommon-devel freetype-devel libarchive-progs clang llvm-devel
        install_pkgs optional apk add ffmpeg xdg-utils fonts-noto-cjk
    elif have apk; then # Alpine and other apk systems
        install_pkgs required apk add wayland-dev libxkbcommon-dev freetype-dev libarchive-tools clang llvm-dev bash
        install_pkgs optional apk add ffmpeg xdg-utils font-noto-cjk
    elif have pacman; then
        install_pkgs required pacman -S --needed --noconfirm wayland libxkbcommon freetype2 libarchive clang
        install_pkgs optional pacman -S --needed --noconfirm ffmpeg xdg-utils noto-fonts-cjk ttf-nerd-fonts-symbols
    elif have apt-get; then
        install_pkgs required apt-get install -y libwayland-dev libxkbcommon-dev libfreetype-dev libarchive-tools clang
        install_pkgs optional apt-get install -y ffmpeg xdg-utils fonts-noto-cjk
    elif have dnf; then
        install_pkgs required dnf install -y wayland-devel libxkbcommon-devel freetype-devel bsdtar clang
        install_pkgs optional dnf install -y ffmpeg-free xdg-utils google-noto-sans-cjk-fonts
    elif have zypper; then
        install_pkgs required zypper --non-interactive install wayland-devel libxkbcommon-devel freetype2-devel bsdtar clang
        install_pkgs optional zypper --non-interactive install ffmpeg xdg-utils noto-sans-cjk-fonts
    elif have xbps-install; then
        install_pkgs required xbps-install -Sy wayland-devel libxkbcommon-devel freetype-devel bsdtar clang
        install_pkgs optional xbps-install -Sy ffmpeg xdg-utils noto-fonts-cjk
    elif have emerge; then
        install_pkgs required emerge --noreplace dev-libs/wayland x11-libs/libxkbcommon media-libs/freetype app-arch/libarchive llvm-core/clang
        install_pkgs optional emerge --noreplace media-video/ffmpeg x11-misc/xdg-utils media-fonts/noto-cjk
    else
        warn "unknown package manager: install wayland, libxkbcommon and freetype (with headers), bsdtar and clang yourself"
    fi
fi

# --- 2. Odin -----------------------------------------------------------------
want=$(echo "$ODIN_TAG" | sed 's/dev-//')
odin_ok() { [ -x "$1" ] && "$1" version 2>/dev/null | grep -q "dev-$want"; }
ODIN=""
if have odin && odin_ok "$(command -v odin)"; then
    ODIN=$(command -v odin)
elif odin_ok "$DATA/odin/odin"; then
    ODIN="$DATA/odin/odin"
else
    mkdir -p "$DATA"
    tmp_odin=$(mktemp -d)
    case "$OS/$(uname -m)/$MUSL" in
    Linux/x86_64/0|Linux/aarch64/0)
        a=amd64; [ "$(uname -m)" = aarch64 ] && a=arm64
        say "downloading Odin $ODIN_TAG"
        curl -fL# "https://github.com/odin-lang/Odin/releases/download/$ODIN_TAG/odin-linux-$a-$ODIN_TAG.tar.gz" | tar -xz -C "$tmp_odin"
        rm -rf "$DATA/odin"
        mv "$tmp_odin"/odin-linux-* "$DATA/odin"
        ;;
    *)
        if [ "$OS" = FreeBSD ] && have odin; then
            ODIN=$(command -v odin) # the ports one: whatever version it is
            warn "using $( "$ODIN" version ) from ports (developed with $ODIN_TAG)"
        else
            # musl (Alpine, Chimera) and others: Odin's own build script, from its source
            say "building Odin $ODIN_TAG from source (needs clang and llvm headers; a minute or two)"
            curl -fL# "https://github.com/odin-lang/Odin/archive/refs/tags/$ODIN_TAG.tar.gz" | tar -xz -C "$tmp_odin"
            (cd "$tmp_odin"/Odin-* && sh ./build_odin.sh release) || die "building Odin failed (is llvm-config from LLVM 17-22 installed?)"
            rm -rf "$DATA/odin"
            mv "$tmp_odin"/Odin-* "$DATA/odin"
        fi
        ;;
    esac
    rm -rf "$tmp_odin"
    [ -z "$ODIN" ] && ODIN="$DATA/odin/odin"
fi
[ -x "$ODIN" ] || die "no usable Odin"
say "using $("$ODIN" version)"

# --- 3. the app --------------------------------------------------------------
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
say "downloading Ame-FileManager ($BRANCH)"
curl -fL# "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$src"
cd "$src"/ame-Filemanager-*
PATH="$(dirname "$ODIN"):$PATH" ./install.sh

# --- 4. icon font --------------------------------------------------------------
fonts="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
if ! { have fc-list && fc-list 2>/dev/null | grep -qi "Symbols Nerd Font"; } && [ ! -e "$fonts/NerdFontsSymbolsOnly" ]; then
    say "adding the Symbols Nerd Font (icons) to $fonts"
    mkdir -p "$fonts/NerdFontsSymbolsOnly"
    if curl -fL# "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.tar.xz" | tar -xJ -C "$fonts/NerdFontsSymbolsOnly"; then
        have fc-cache && fc-cache -f "$fonts" >/dev/null 2>&1 || true
    else
        warn "could not download the icon font; install a Symbols Nerd Font package for icons"
    fi
fi

case ":$PATH:" in
*":$PREFIX/bin:"*) ;;
*) warn "$PREFIX/bin is not on your PATH (the launcher entry works anyway)" ;;
esac
say "done — start it from your app launcher or with: $PREFIX/bin/ame-filemanager"
