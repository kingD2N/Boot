#!/usr/bin/env bash
# fetch_input.sh — Ambil file input dari berbagai sumber.
#
# Pemakaian: ./scripts/fetch_input.sh <sumber> <folder-tujuan> <kernel|boot>
# Path file hasil dicetak ke stdout (baris terakhir). Log ke stderr.
#
# Format <sumber>:
#   https://...                     link langsung (GitHub release, SourceForge, dll.)
#   https://drive.google.com/...    Google Drive (pakai gdown)
#   release:TAG                     asset dari release repo ini (TAG boleh 'latest')
#   release:TAG/POLA                contoh: release:stock/boot.img
#   release:OWNER/REPO@TAG/POLA     asset dari release repo lain (publik)
#   path/di/repo                    file yang ada di repo ini
#
# Untuk 'boot', file yang diterima: boot.img, .img.xz/.img.gz, zip/tgz berisi boot.img
# (mis. ROM fastboot Xiaomi), atau zip ROM / payload.bin (pakai payload-dumper-go).

set -euo pipefail
log() { printf '[fetch] %s\n' "$*" >&2; }
die() { printf '[fetch][x] %s\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$*" >&2; exit 1; }

[ $# -eq 3 ] || die "Pemakaian: $0 <sumber> <folder-tujuan> <kernel|boot>"
SRC=$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
DEST=$(realpath -m "$2")
KIND=$3
[ -n "$SRC" ] || die "Sumber $KIND kosong"
case "$KIND" in kernel|boot) ;; *) die "Jenis harus kernel atau boot" ;; esac

DL="$DEST/dl"
rm -rf "$DL"; mkdir -p "$DL"

newest() { find "$1" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-; }

# ------------------------------------------------------------------ unduh
case "$SRC" in
  http://*drive.google.com*|https://*drive.google.com*|https://drive.usercontent.google.com*)
    log "Unduh dari Google Drive"
    command -v gdown >/dev/null || pip install -q gdown >&2
    gdown --fuzzy -q "$SRC" -O "$DL/" >&2 || die "Gagal unduh dari Google Drive (pastikan link dibagikan 'Siapa saja yang memiliki link')"
    FILE=$(newest "$DL") ;;
  http://*|https://*)
    log "Unduh: $SRC"
    (cd "$DL" && curl -fSL --retry 3 --retry-delay 5 -OJ "$SRC" >&2) || die "Gagal unduh $SRC"
    FILE=$(newest "$DL") ;;
  release:*)
    spec=${SRC#release:}
    if [[ "$spec" == *@* ]]; then repo=${spec%%@*}; rest=${spec#*@}
    else repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY belum di-set}; rest=$spec; fi
    tag=${rest%%/*}
    if [[ "$rest" == */* ]]; then pat=${rest#*/}
    elif [ "$KIND" = kernel ]; then pat='*.zip'
    else pat='*boot*'; fi
    log "Unduh asset release $repo tag=$tag pola=$pat"
    args=(-R "$repo" -p "$pat" -D "$DL" --clobber)
    if [ "$tag" = latest ] || [ -z "$tag" ]; then gh release download "${args[@]}" >&2
    else gh release download "$tag" "${args[@]}" >&2; fi || die "Gagal unduh asset release ($repo $tag $pat)"
    n=$(find "$DL" -maxdepth 1 -type f | wc -l)
    [ "$n" -ge 1 ] || die "Tidak ada asset cocok dengan pola '$pat'"
    [ "$n" -eq 1 ] || log "Ada $n asset cocok, dipakai yang terbaru. Perjelas POLA bila salah."
    FILE=$(newest "$DL") ;;
  *)
    p=${GITHUB_WORKSPACE:-.}/$SRC
    [ -f "$p" ] || p=$SRC
    [ -f "$p" ] || die "File tidak ditemukan di repo: $SRC"
    cp "$p" "$DL/"
    FILE=$(newest "$DL") ;;
esac
[ -n "${FILE:-}" ] && [ -s "$FILE" ] || die "File $KIND hasil unduhan kosong"
log "Didapat: $(basename "$FILE") ($(stat -c %s "$FILE") byte)"

magic() { head -c 8 "$1" | od -An -tx1 | tr -d ' \n'; }

# ------------------------------------------------------------------ kernel
if [ "$KIND" = kernel ]; then
  case "$(magic "$FILE")" in 504b0304*) ;; *) die "Kernel harus berupa .zip AnyKernel3 (file yang didapat bukan zip)";; esac
  case "$FILE" in *.zip) ;; *) mv "$FILE" "$FILE.zip"; FILE="$FILE.zip";; esac
  echo "$FILE"; exit 0
fi

# ------------------------------------------------------------------ boot
extract_payload() {  # $1 = payload.bin
  local pd
  if ! command -v payload-dumper-go >/dev/null; then
    log "Pasang payload-dumper-go"
    pd=$(mktemp -d)
    gh release download -R ssut/payload-dumper-go -p '*linux_amd64.tar.gz' -D "$pd" >&2 \
      || die "Gagal unduh payload-dumper-go"
    tar -xzf "$pd"/*.tar.gz -C "$pd"
    export PATH="$pd:$PATH"
  fi
  mkdir -p "$DEST/payload"
  payload-dumper-go -p boot -o "$DEST/payload" "$1" >&2 || die "Gagal ekstrak boot dari payload.bin"
  [ -f "$DEST/payload/boot.img" ] || die "payload.bin tidak berisi partisi boot"
  mv "$DEST/payload/boot.img" "$DEST/boot.img"
}

OUTB="$DEST/boot.img"
for _ in 1 2 3; do
  # tar (mis. ROM fastboot Xiaomi .tgz setelah gzip dibuka): "ustar" di offset 257
  if [ "$(dd if="$FILE" bs=1 skip=257 count=5 2>/dev/null)" = ustar ]; then
    entry=$(tar -tf "$FILE" | grep -E '(^|/)boot\.img$' | head -n1 || true)
    [ -n "$entry" ] || die "Arsip tar tidak berisi boot.img"
    log "Ekstrak $entry dari tar"
    tar -xOf "$FILE" "$entry" > "$OUTB"; rm -f "$FILE"; echo "$OUTB"; exit 0
  fi
  case "$(magic "$FILE")" in
    414e44524f494421*)  # "ANDROID!"
      [ "$FILE" = "$OUTB" ] || mv "$FILE" "$OUTB"
      echo "$OUTB"; exit 0 ;;
    fd377a585a00*)      # xz
      log "Dekompres xz"; xz -dc "$FILE" > "$DEST/unpacked.bin"; rm -f "$FILE"; FILE="$DEST/unpacked.bin" ;;
    1f8b*)              # gzip
      log "Dekompres gzip"; gzip -dc "$FILE" > "$DEST/unpacked.bin"; rm -f "$FILE"; FILE="$DEST/unpacked.bin" ;;
    43724155*)          # "CrAU" payload.bin
      log "payload.bin terdeteksi"; extract_payload "$FILE"; echo "$OUTB"; exit 0 ;;
    504b0304*)          # zip
      list=$(unzip -Z1 "$FILE")
      entry=$(printf '%s\n' "$list" | grep -E '(^|/)boot\.img$' | head -n1 || true)
      if [ -n "$entry" ]; then
        log "Ekstrak $entry dari zip"
        unzip -p "$FILE" "$entry" > "$OUTB"; echo "$OUTB"; exit 0
      fi
      entry=$(printf '%s\n' "$list" | grep -E '(^|/)payload\.bin$' | head -n1 || true)
      if [ -n "$entry" ]; then
        log "Ekstrak $entry dari zip ROM (bisa lama)"
        unzip -p "$FILE" "$entry" > "$DEST/payload.bin"; rm -f "$FILE"
        extract_payload "$DEST/payload.bin"; rm -f "$DEST/payload.bin"; echo "$OUTB"; exit 0
      fi
      die "Zip tidak berisi boot.img maupun payload.bin" ;;
    *) die "Format file boot tidak dikenali (bukan boot.img/zip/xz/gz/payload.bin)" ;;
  esac
done
die "Gagal mengenali file boot setelah dekompres berulang"
