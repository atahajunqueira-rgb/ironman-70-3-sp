#!/usr/bin/env bash
# Monta um Reels vertical (1080x1920, 30fps, sem áudio, sem texto) a partir
# de vários clipes de celular (.MOV do iPhone, inclusive HDR/Dolby Vision).
#
# Uso:
#   ./editar_reels.sh <pasta_com_videos> [saida.mp4]
#
# Variáveis opcionais:
#   HOOK=IMG_6870   clipe que abre o vídeo (o mais impactante: vista, cume, chegada)
#   FINAL=IMG_6875  clipe que fecha o vídeo (ex.: chegada / comemoração)
#   SEG=2.2         duração de cada corte em segundos (ritmo; 1.8–2.5 funciona bem)
#   STAB=1          estabiliza cada corte com vid.stab (0 desliga)
#   CUTS="IMG_6840=12.5 IMG_6847=3"  início manual (s) do corte de cada clipe;
#                   sem isso, usa o trecho de maior movimento do clipe
set -euo pipefail

IN_DIR=${1:?informe a pasta com os vídeos}
OUT=${2:-reels_trilha.mp4}
SEG=${SEG:-2.2}
STAB=${STAB:-1}
HOOK=${HOOK:-}
FINAL=${FINAL:-}
CUTS=${CUTS:-}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mapfile -t CLIPS < <(find "$IN_DIR" -maxdepth 1 -type f \( -iname '*.mov' -o -iname '*.mp4' \) | sort)
[ ${#CLIPS[@]} -gt 0 ] || { echo "nenhum vídeo em $IN_DIR"; exit 1; }

# Ordem: gancho primeiro, depois ordem cronológica (numeração do iPhone), final por último.
ordered=()
for c in "${CLIPS[@]}"; do [ -n "$HOOK" ] && [[ $(basename "$c") == "$HOOK"* ]] && ordered+=("$c"); done
for c in "${CLIPS[@]}"; do
  b=$(basename "$c")
  [ -n "$HOOK" ] && [[ $b == "$HOOK"* ]] && continue
  [ -n "$FINAL" ] && [[ $b == "$FINAL"* ]] && continue
  ordered+=("$c")
done
for c in "${CLIPS[@]}"; do [ -n "$FINAL" ] && [[ $(basename "$c") == "$FINAL"* ]] && ordered+=("$c"); done

manual_cut() {
  local name=$1 kv
  for kv in $CUTS; do [[ $name == "${kv%%=*}"* ]] && { echo "${kv#*=}"; return; }; done
}

# Início do trecho com mais movimento (média de YDIF por janela de SEG s),
# ignorando o 1º e o último segundo, onde o celular costuma estar se ajeitando.
best_start() {
  local f=$1 dur=$2
  ffmpeg -nostdin -hide_banner -loglevel error -i "$f" \
    -vf "fps=5,scale=160:-2,signalstats,metadata=print:key=lavfi.signalstats.YDIF:file=-" \
    -an -f null - 2>/dev/null |
  awk -v seg="$SEG" -v dur="$dur" '
    /pts_time/ { split($0, a, "pts_time:"); t = a[2] + 0 }
    /YDIF=/    { split($0, a, "="); n++; T[n] = t; Y[n] = a[2] + 0 }
    END {
      lo = 1; hi = dur - 1 - seg; if (hi < lo) { lo = 0; hi = dur - seg }
      if (hi < 0) { print 0; exit }
      best = lo; bs = -1
      for (s = lo; s <= hi; s += 0.2) {
        sum = 0; k = 0
        for (i = 1; i <= n; i++) if (T[i] >= s && T[i] < s + seg) { sum += Y[i]; k++ }
        if (k && sum / k > bs) { bs = sum / k; best = s }
      }
      printf "%.2f\n", best
    }'
}

i=0
list="$WORK/list.txt"; : > "$list"
for f in "${ordered[@]}"; do
  i=$((i + 1))
  name=$(basename "$f")
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$f")

  start=$(manual_cut "$name")
  [ -n "$start" ] || start=$(best_start "$f" "$dur")

  # Primeiro corte e último ficam um pouco mais longos (gancho e respiro final).
  len=$SEG
  [ $i -eq 1 ] && len=$(awk -v s="$SEG" 'BEGIN{print s + 0.6}')
  [ $i -eq ${#ordered[@]} ] && len=$(awk -v s="$SEG" 'BEGIN{print s + 1.0}')

  # HDR (HLG/PQ do iPhone) -> SDR Rec.709; sem isso o vídeo fica lavado no Instagram.
  tm=""
  if [[ $trc == arib-std-b67 || $trc == smpte2084 ]]; then
    tm="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,"
  fi

  # Enquadramento 9:16 + leve "push-in" (zoom de 4% ao longo do corte) para dar dinamismo.
  frame="scale=1080:1920:force_original_aspect_ratio=increase,scale=w='trunc(iw*(1+0.04*t/$len)/2)*2':h='trunc(ih*(1+0.04*t/$len)/2)*2':eval=frame,crop=1080:1920"
  # Cor: contraste e vibração leves, tons de natureza mais vivos sem estourar pele.
  grade="eq=contrast=1.07:brightness=0.01:saturation=1.08:gamma=0.98,vibrance=intensity=0.18,unsharp=5:5:0.6"

  stab=""
  if [ "$STAB" = 1 ]; then
    ffmpeg -nostdin -hide_banner -loglevel error -ss "$start" -t "$len" -i "$f" \
      -vf "vidstabdetect=shakiness=6:accuracy=12:result=$WORK/t$i.trf" -an -f null -
    stab="vidstabtransform=input=$WORK/t$i.trf:smoothing=20:zoom=4,"
  fi

  echo "[$i/${#ordered[@]}] $name  início=${start}s  duração=${len}s  ${trc:-sdr}"
  ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$start" -t "$len" -i "$f" \
    -vf "${tm}${stab}fps=30,${frame},${grade},setsar=1,format=yuv420p" \
    -an -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    "$WORK/c$(printf %02d $i).mp4"
  echo "file '$WORK/c$(printf %02d $i).mp4'" >> "$list"
done

# Junta os cortes secos (cortes rápidos retêm mais que transições) e
# exporta no padrão recomendado pelo Instagram para Reels.
ffmpeg -nostdin -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" \
  -an \
  -c:v libx264 -preset slow -profile:v high -level 4.1 -crf 18 -maxrate 12M -bufsize 24M \
  -r 30 -g 60 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -movflags +faststart "$OUT"

echo "Pronto: $OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s)"
