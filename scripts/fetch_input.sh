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
#   release:OWNER/REPO@TAG/POLA     asset dari release repo lain
#   path/di/repo                    file yang ada di repo ini
#
# Untuk release: bila beberapa asset cocok dengan POLA, dipilih yang PALING BARU di-upload.
# Beberapa sumber bisa dipisah "||" -> dicoba berurutan, yang pertama berhasil dipakai.
#
# RESOLVE_ONLY=1 -> tidak mengunduh, hanya cetak "ID<TAB>NAMA<TAB>WAKTU" asset terpilih
#                   ("-<TAB>sumber<TAB>-" untuk sumber non-release). Dipakai untuk auto-build.
# Info asset terpilih juga ditulis ke <folder-tujuan>/asset.env
#
# Untuk 'boot', file yang diterima: boot.img, .img.xz/.img.gz, zip/tgz berisi boot.img
# (mis. ROM fastboot Xiaomi), atau zip ROM / payload.bin (partisi boot dibaca langsung
# lewat scripts/ota_boot.py; untuk URL .zip cukup unduh ~100 MB via HTTP Range).

set -euo pipefail
log() { printf '[fetch] %s\n' "$*" >&2; }
die() { printf '[fetch][x] %s\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$*" >&2; exit 1; }

[ $# -eq 3 ] || die "Pemakaian: $0 <sumber> <folder-tujuan> <kernel|boot>"
DEST=$(realpath -m "$2")
KIND=$3
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
case "$KIND" in kernel|boot) ;; *) die "Jenis harus kernel atau boot" ;; esac
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
mapfile -t ALTS < <(printf '%s\n' "$1" | sed 's/[[:space:]]*||[[:space:]]*/\n/g')

DL="$DEST/dl"
newest() { find "$1" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-; }

# resolve_release <spec tanpa "release:"> -> set R_REPO R_TAG R_ID R_NAME R_TIME
resolve_release() {
  local spec=$1 rest pat api json t id name
  if [[ "$spec" == *@* ]]; then R_REPO=${spec%%@*}; rest=${spec#*@}
  else R_REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY belum di-set}; rest=$spec; fi
  R_TAG=${rest%%/*}
  if [[ "$rest" == */* ]]; then pat=${rest#*/}
  elif [ "$KIND" = kernel ]; then pat='*.zip'
  else pat='*boot*'; fi
  if [ -z "$R_TAG" ] || [ "$R_TAG" = latest ]; then api="repos/$R_REPO/releases/latest"
  else api="repos/$R_REPO/releases/tags/$R_TAG"; fi
  json=$(gh api "$api" 2>/dev/null) || { log "Release tidak ditemukan: $R_REPO tag=${R_TAG:-latest}"; return 1; }
  R_ID=""; R_NAME=""; R_TIME=""
  while IFS=$'\t' read -r t id name; do
    # shellcheck disable=SC2053
    [[ "$name" == $pat ]] || continue
    if [ -z "$R_TIME" ] || [[ "$t" > "$R_TIME" ]]; then R_TIME=$t; R_ID=$id; R_NAME=$name; fi
  done < <(jq -r '.assets[] | [.updated_at, (.id|tostring), .name] | @tsv' <<<"$json")
  [ -n "$R_ID" ] || { log "Tidak ada asset cocok '$pat' di $R_REPO tag=${R_TAG:-latest}"; return 1; }
  log "Asset terpilih: $R_NAME (id $R_ID, $R_TIME) dari $R_REPO@${R_TAG:-latest}"
}

# fetch_one <sumber> -> set FILE, ASSET_*; return 1 bila gagal
fetch_one() {
  local src=$1 p
  rm -rf "$DL"; mkdir -p "$DL"
  ASSET_ID=-; ASSET_NAME=$src; ASSET_TIME=-; ASSET_REPO=-
  case "$src" in
    http://*drive.google.com*|https://*drive.google.com*|https://drive.usercontent.google.com*)
      log "Unduh dari Google Drive"
      command -v gdown >/dev/null || pip install -q gdown >&2
      gdown --fuzzy -q "$src" -O "$DL/" >&2 || { log "Gagal unduh dari Google Drive (link harus 'Siapa saja yang memiliki link')"; return 1; } ;;
    http://*|https://*)
      local path=${src%%\?*} rc=0
      if [ "$KIND" = boot ] && [[ "$path" == *.zip ]]; then
        # ROM OTA/recovery: ambil partisi boot saja lewat HTTP Range (~100 MB, bukan 5 GB)
        log "Ambil boot dari ROM OTA via HTTP Range: $src"
        python3 -I "$SCRIPT_DIR/ota_boot.py" "$src" "$DL/boot.img" >&2 || rc=$?
        case $rc in
          0) ;;
          3|4) log "Range/format tidak didukung (kode $rc) -> unduh penuh"
               (cd "$DL" && curl -fsSL --retry 3 --retry-delay 5 -OJ "$src" >&2) || { log "Gagal unduh $src"; return 1; } ;;
          *) log "Gagal ambil boot dari $src (kode $rc)"; return 1 ;;
        esac
      elif [ "$KIND" = boot ] && [[ "$path" == *.tgz || "$path" == *.tar.gz ]]; then
        # ROM fastboot: stream & ambil images/boot.img tanpa menyimpan arsip 6+ GB
        log "Stream ROM fastboot & ambil images/boot.img: $src"
        curl -fsSL --retry 3 --retry-delay 5 "$src" \
          | tar -xzOf - --wildcards '*images/boot.img' > "$DL/boot.img" \
          || { log "Gagal stream/ekstrak boot.img dari $src"; rm -f "$DL/boot.img"; return 1; }
      else
        log "Unduh: $src"
        (cd "$DL" && curl -fsSL --retry 3 --retry-delay 5 -OJ "$src" >&2) || { log "Gagal unduh $src"; return 1; }
      fi ;;
    release:*)
      resolve_release "${src#release:}" || return 1
      gh api -H "Accept: application/octet-stream" "repos/$R_REPO/releases/assets/$R_ID" > "$DL/$R_NAME" \
        || { log "Gagal unduh asset $R_NAME"; return 1; }
      ASSET_ID=$R_ID; ASSET_NAME=$R_NAME; ASSET_TIME=$R_TIME; ASSET_REPO=$R_REPO ;;
    *)
      p=${GITHUB_WORKSPACE:-.}/$src
      [ -f "$p" ] || p=$src
      [ -f "$p" ] || { log "File tidak ditemukan di repo: $src"; return 1; }
      cp "$p" "$DL/" ;;
  esac
  FILE=$(newest "$DL")
  [ -n "${FILE:-}" ] && [ -s "$FILE" ] || { log "File $KIND hasil unduhan kosong"; return 1; }
}

# ------------------------------------------------------------------ mode cek saja
if [ "${RESOLVE_ONLY:-0}" = 1 ]; then
  for a in "${ALTS[@]}"; do
    a=$(trim "$a"); [ -n "$a" ] || continue
    case "$a" in
      release:*) resolve_release "${a#release:}" && { printf '%s\t%s\t%s\n' "$R_ID" "$R_NAME" "$R_TIME"; exit 0; } ;;
      http://*|https://*)
        # pastikan link hidup (ambil 1 byte); link mati -> coba sumber berikutnya
        if curl -fsSL -r 0-0 -o /dev/null --max-time 45 --retry 2 "$a" 2>/dev/null; then
          printf -- '-\t%s\t-\n' "$a"; exit 0
        fi
        log "Tidak bisa dijangkau: $a" ;;
      *) { [ -f "${GITHUB_WORKSPACE:-.}/$a" ] || [ -f "$a" ]; } && { printf -- '-\t%s\t-\n' "$a"; exit 0; } ;;
    esac
  done
  log "Tidak ada sumber $KIND yang tersedia: $1"; exit 1
fi

# ------------------------------------------------------------------ unduh
FILE=""
for a in "${ALTS[@]}"; do
  a=$(trim "$a"); [ -n "$a" ] || continue
  if fetch_one "$a"; then break; fi
  FILE=""
done
[ -n "$FILE" ] || die "Semua sumber $KIND gagal: $1"
mkdir -p "$DEST"
printf 'ASSET_ID=%q\nASSET_NAME=%q\nASSET_TIME=%q\nASSET_REPO=%q\n' "$ASSET_ID" "$ASSET_NAME" "$ASSET_TIME" "$ASSET_REPO" > "$DEST/asset.env"
log "Didapat: $(basename "$FILE") ($(stat -c %s "$FILE") byte)"

magic() { head -c 8 "$1" | od -An -tx1 | tr -d ' \n'; }

# ------------------------------------------------------------------ kernel
if [ "$KIND" = kernel ]; then
  case "$(magic "$FILE")" in 504b0304*) ;; *) die "Kernel harus berupa .zip AnyKernel3 (file yang didapat bukan zip)";; esac
  case "$FILE" in *.zip) ;; *) mv "$FILE" "$FILE.zip"; FILE="$FILE.zip";; esac
  echo "$FILE"; exit 0
fi

# ------------------------------------------------------------------ boot
extract_payload() {  # $1 = zip OTA atau payload.bin lokal -> $DEST/boot.img (dibaca langsung, tanpa ekstrak payload)
  python3 -I "$SCRIPT_DIR/ota_boot.py" "$1" "$DEST/boot.img.new" >&2 || die "Gagal ekstrak partisi boot dari payload"
  rm -f "$1"
  mv "$DEST/boot.img.new" "$DEST/boot.img"
}

OUTB="$DEST/boot.img"
for _ in 1 2 3; do
  # tar (mis. ROM fastboot Xiaomi .tgz setelah gzip dibuka): "ustar" di offset 257
  if [ "$(dd if="$FILE" bs=1 skip=257 count=5 2>/dev/null | tr -d '\0')" = ustar ]; then
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
        log "Ambil partisi boot dari payload.bin di dalam zip ROM"
        extract_payload "$FILE"; echo "$OUTB"; exit 0
      fi
      die "Zip tidak berisi boot.img maupun payload.bin" ;;
    *) die "Format file boot tidak dikenali (bukan boot.img/zip/xz/gz/payload.bin)" ;;
  esac
done
die "Gagal mengenali file boot setelah dekompres berulang"
