#!/usr/bin/env bash
# patch_boot.sh — Pasang kernel dari zip AnyKernel3 ke boot.img stock.
#
# Pemakaian:
#   MAGISKBOOT=/path/magiskboot ./scripts/patch_boot.sh <kernel.zip> <stock-boot.img> <outdir> [nama-output]
#
# Cara kerja (meniru yang dilakukan AnyKernel3 di recovery):
#   1. Ekstrak zip AK3, cari image kernel (Image / Image.gz / Image.lz4 / *-dtb).
#   2. Unpack boot.img stock dengan magiskboot.
#   3. Ganti file `kernel` (dan `dtb` bila zip membawanya).
#   4. Repack -> magiskboot otomatis mengompres kernel sesuai format stock
#      dan mempertahankan footer AVB / ukuran image.
#
# Yang TIDAK bisa dimasukkan ke boot.img (akan diberi peringatan):
#   - dtbo.img      -> disalin terpisah ke outdir, flash ke partisi dtbo.
#   - modules/*.ko  -> AK3 memasangnya ke /vendor saat flash di recovery.
#   - ramdisk/ & patch/ dari anykernel.sh -> tidak dieksekusi di sini.

set -euo pipefail

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$*"; return 0; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$*"; exit 1; }

[ $# -ge 3 ] || die "Pemakaian: $0 <kernel.zip> <stock-boot.img> <outdir> [nama-output]"

KZIP=$(realpath "$1")
STOCK=$(realpath "$2")
OUT=$(realpath -m "$3")
OUTNAME=${4:-}
MB=${MAGISKBOOT:-magiskboot}
DEVICE=${DEVICE:-ingres}

command -v "$MB" >/dev/null 2>&1 || [ -x "$MB" ] || die "magiskboot tidak ditemukan (set MAGISKBOOT=...)"
MB=$(command -v "$MB" || echo "$MB")
[ -f "$KZIP" ]  || die "Zip kernel tidak ada: $KZIP"
[ -f "$STOCK" ] || die "boot.img stock tidak ada: $STOCK"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/ak3" "$WORK/boot"

# ---------------------------------------------------------------- 1. ekstrak zip
log "Ekstrak zip kernel: $(basename "$KZIP")"
unzip -q -o "$KZIP" -d "$WORK/ak3" || die "Gagal ekstrak zip kernel"
AK="$WORK/ak3"

if [ -f "$AK/anykernel.sh" ]; then
  KSTRING=$(sed -n "s/^[[:space:]]*kernel\.string=\(.*\)$/\1/p" "$AK/anykernel.sh" | head -n1 | tr -d "'\"")
  [ -n "$KSTRING" ] && log "kernel.string : $KSTRING"
  DEVCHECK=$(sed -n 's/^[[:space:]]*do\.devicecheck=\([0-9]\).*/\1/p' "$AK/anykernel.sh" | head -n1)
  DEVNAMES=$(sed -n 's/^[[:space:]]*device\.name[0-9]*=\(.*\)$/\1/p' "$AK/anykernel.sh" | tr -d "'\"" | grep -v '^$' | tr '\n' ' ' || true)
  if [ "${DEVCHECK:-0}" = 1 ] && [ -n "$DEVNAMES" ] && ! printf ' %s ' "$DEVNAMES" | grep -qw "$DEVICE"; then
    warn "anykernel.sh menargetkan device: $DEVNAMES — bukan '$DEVICE'. Pastikan zip ini benar!"
  fi
else
  warn "anykernel.sh tidak ditemukan — zip bukan format AnyKernel3 standar, tetap mencoba mencari Image."
fi

# Cari image kernel. Urutan sama dengan prioritas AnyKernel3.
KIMG=""
for n in Image.gz-dtb Image.lz4-dtb Image-dtb Image.gz Image.lz4 Image zImage-dtb zImage; do
  if [ -f "$AK/$n" ]; then KIMG="$AK/$n"; break; fi
done
if [ -z "$KIMG" ]; then
  # fallback: cari di subfolder (kecuali folder tools/modules/ramdisk/patch milik AK3)
  KIMG=$(find "$AK" -type f \( -name 'Image*' -o -name 'zImage*' \) \
           -not -path '*/tools/*' -not -path '*/modules/*' \
           -not -path '*/ramdisk/*' -not -path '*/patch/*' | head -n1)
fi
[ -n "$KIMG" ] || die "Tidak ada Image/Image.gz/Image.lz4 di dalam zip kernel"
log "Image kernel  : ${KIMG#"$AK"/} ($(stat -c %s "$KIMG") byte)"

# ---------------------------------------------------------------- 2. unpack stock
cd "$WORK/boot"
log "Unpack boot.img stock: $(basename "$STOCK") ($(stat -c %s "$STOCK") byte)"
set +e
"$MB" unpack -h "$STOCK" 2>&1 | tee "$WORK/unpack.log"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" -eq 0 ] || die "magiskboot unpack gagal (kode $rc). Apakah file ini benar boot.img?"
[ -f kernel ] || die "boot.img stock tidak berisi kernel (mungkin ini init_boot/vendor_boot?)"

STOCK_KFMT=$(sed -n 's/^KERNEL_FMT[[:space:]]*\[\(.*\)\]/\1/p' "$WORK/unpack.log" | head -n1)
HDRVER=$(sed -n 's/^HEADER_VER[[:space:]]*\[\(.*\)\]/\1/p' "$WORK/unpack.log" | head -n1)
log "Header v${HDRVER:-?}, format kernel stock: ${STOCK_KFMT:-raw}"
OLD_KVER=$(strings kernel 2>/dev/null | grep -m1 -E '^Linux version [0-9]' || true)

# ---------------------------------------------------------------- 3. ganti kernel
is_raw_arm64() {  # Image arm64 mentah: magic "ARMd" di offset 0x38
  [ "$(dd if="$1" bs=1 skip=56 count=4 2>/dev/null)" = "ARMd" ]
}

rm -f kernel
case "$(basename "$KIMG")" in
  *-dtb)
    # kernel + dtb tergabung: biarkan apa adanya (sama seperti AK3)
    cp "$KIMG" kernel ;;
  *)
    if is_raw_arm64 "$KIMG"; then
      cp "$KIMG" kernel
    else
      log "Dekompres $(basename "$KIMG") -> raw (repack akan mengompres ulang sesuai format stock)"
      "$MB" decompress "$KIMG" kernel || die "Gagal dekompres $(basename "$KIMG")"
    fi ;;
esac
is_raw_arm64 kernel || warn "Kernel baru tidak terdeteksi sebagai Image arm64 mentah — periksa hasilnya."

NEW_KVER=$(strings kernel 2>/dev/null | grep -m1 -E '^Linux version [0-9]' || true)
log "Kernel lama  : ${OLD_KVER:-?}"
log "Kernel baru  : ${NEW_KVER:-?}"

# dtb: hanya ganti bila stock memang punya dtb di boot.img
if [ -f "$AK/dtb" ]; then
  if [ -f dtb ]; then log "Mengganti dtb dari zip"; cp "$AK/dtb" dtb
  else warn "Zip membawa 'dtb' tapi boot.img stock tidak punya dtb (GKI: dtb ada di vendor_boot) — diabaikan."; fi
fi

# dtbo terpisah
DTBO=""
for d in dtbo.img dtbo_oem.img; do
  [ -f "$AK/$d" ] && DTBO="$AK/$d" && break
done

# peringatan untuk hal yang tidak bisa diterapkan
if [ -d "$AK/modules" ] && find "$AK/modules" -type f -name '*.ko' | grep -q .; then
  warn "Zip berisi modul .ko — modul TIDAK masuk ke boot.img. Flash zip lewat recovery bila modul wajib."
fi
if [ -d "$AK/ramdisk" ] && find "$AK/ramdisk" -type f ! -name placeholder | grep -q .; then
  warn "Zip berisi folder ramdisk/ — modifikasi ramdisk anykernel.sh tidak diterapkan."
fi

# ---------------------------------------------------------------- 4. repack
log "Repack boot.img"
"$MB" repack "$STOCK" "$WORK/new-boot.img" 2>&1 | tee "$WORK/repack.log"
[ -s "$WORK/new-boot.img" ] || die "magiskboot repack tidak menghasilkan file"

SSZ=$(stat -c %s "$STOCK"); NSZ=$(stat -c %s "$WORK/new-boot.img")
log "Ukuran stock: $SSZ byte | hasil: $NSZ byte"
if [ "$NSZ" -gt "$SSZ" ]; then
  warn "boot.img hasil LEBIH BESAR dari stock. Bila stock adalah dump partisi penuh, image ini tidak akan muat!"
fi

# verifikasi: unpack hasil dan cocokkan kernel
mkdir -p "$WORK/verify" && cd "$WORK/verify"
"$MB" unpack "$WORK/new-boot.img" >/dev/null 2>&1 || die "Verifikasi gagal: boot.img hasil tidak bisa di-unpack"
case "$(basename "$KIMG")" in
  *-dtb) log "Image *-dtb: verifikasi byte-per-byte dilewati (kernel & dtb dipisah saat unpack)" ;;
  *)
    cmp -s kernel "$WORK/boot/kernel" || die "Verifikasi gagal: kernel di boot.img hasil tidak sama dengan kernel dari zip"
    log "Verifikasi OK: kernel di boot.img hasil identik dengan Image dari zip" ;;
esac

# ---------------------------------------------------------------- output
if [ -z "$OUTNAME" ]; then
  OUTNAME="boot-$(basename "$KZIP" .zip).img"
fi
cp "$WORK/new-boot.img" "$OUT/$OUTNAME"
[ -n "$DTBO" ] && cp "$DTBO" "$OUT/$(basename "$DTBO")" && log "dtbo ikut disalin: $(basename "$DTBO") (flash ke partisi dtbo)"

{
  echo "Kernel zip    : $(basename "$KZIP")"
  echo "Stock boot    : $(basename "$STOCK") (sha256 $(sha256sum "$STOCK" | cut -d' ' -f1))"
  echo "kernel.string : ${KSTRING:-?}"
  echo "Kernel lama   : ${OLD_KVER:-?}"
  echo "Kernel baru   : ${NEW_KVER:-?}"
  echo "Header        : v${HDRVER:-?}, format kernel ${STOCK_KFMT:-raw}"
  echo
  (cd "$OUT" && sha256sum -- *.img)
} > "$OUT/info.txt"

log "Selesai -> $OUT/$OUTNAME"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "boot_img=$OUT/$OUTNAME"
    echo "boot_name=$OUTNAME"
    echo "kernel_string=${KSTRING:-}"
    echo "kernel_version=${NEW_KVER:-}"
  } >> "$GITHUB_OUTPUT"
fi
