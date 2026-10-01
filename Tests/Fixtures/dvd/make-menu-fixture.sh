#!/bin/bash
# Builds Tests/Fixtures/dvd/menu-test.iso: a tiny NTSC DVD-Video with real navigation, used by the
# DVD menu VM tests (DVDMenuFixtureTests). Tools are fixture-only and never linked into the engine:
#   brew install ffmpeg dvdauthor xorriso
# Layout (see menu-test.xml):
#   FP PGC          g1 = 1; jump VMGM title menu
#   VMGM title menu 3 buttons on a still (pause=inf):
#                     b1 "Play"      -> jump title 1
#                     b2 "Chapters"  -> jump titleset 1 root menu (VTSM chapter menu)
#                     b3 "Extra"     -> g2 = 7; jump title 2      (GPRM set, then jump)
#   VTSM root menu  3 buttons: chapter 1, chapter 2 of title 1, back to VMGM menu
#   Title 1         2 chapters (2 s), post: call VMGM title menu
#   Title 2         1 s, post: g2 == 7 ? call VTSM root menu : call VMGM title menu
# Output is deterministic enough for structural tests (sector numbers can shift between tool versions,
# so tests assert structure, not absolute sectors).
set -euo pipefail
cd "$(dirname "$0")"
command -v dvdauthor >/dev/null && command -v spumux >/dev/null && command -v xorriso >/dev/null && command -v ffmpeg >/dev/null \
  || { echo "need ffmpeg dvdauthor spumux xorriso (brew install ffmpeg dvdauthor xorriso)"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export VIDEO_FORMAT=NTSC

clip() { # name seconds colour
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=$3:s=720x480:r=30000/1001:d=$2" \
    -f lavfi -i "anullsrc=r=48000:cl=stereo" -t "$2" -target ntsc-dvd -b:v 400k -maxrate 1500k -bufsize 1835k \
    -b:a 64k -ac 2 -aspect 4:3 -flags +bitexact -fflags +bitexact "$W/$1.mpg"
}
buttons_png() { # name colour  (3 boxes, 4-colour-safe: transparent + one colour)
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black@0.0:s=720x480,format=rgba" -frames:v 1 \
    -vf "drawbox=x=100:y=100:w=200:h=60:color=$2@1.0:t=4,drawbox=x=100:y=200:w=200:h=60:color=$2@1.0:t=4,drawbox=x=100:y=300:w=200:h=60:color=$2@1.0:t=4" \
    "$W/$1.png"
}

clip vmgm_bg 1 navy
clip vtsm_bg 1 darkgreen
clip title1 2 gray
clip title2 1 maroon
buttons_png hl yellow
buttons_png sel red

for m in vmgm vtsm; do
  cat > "$W/$m-spu.xml" <<XML
<subpictures format="NTSC"><stream><spu start="00:00:00.00" force="yes" highlight="$W/hl.png" select="$W/sel.png">
  <button name="b1" x0="100" y0="100" x1="300" y1="160" down="b2" up="b3"/>
  <button name="b2" x0="100" y0="200" x1="300" y1="260" up="b1" down="b3"/>
  <button name="b3" x0="100" y0="300" x1="300" y1="360" up="b2" down="b1"/>
</spu></stream></subpictures>
XML
  spumux -m dvd "$W/$m-spu.xml" < "$W/${m}_bg.mpg" > "$W/${m}_menu.mpg" 2>"$W/$m-spumux.log"
done

cat > "$W/menu-test.xml" <<XML
<dvdauthor dest="$W/DVD" jumppad="0">
  <vmgm>
    <fpc>g1 = 1; jump vmgm menu 1;</fpc>
    <menus>
      <video format="ntsc" aspect="4:3"/>
      <pgc entry="title" pause="inf">
        <vob file="$W/vmgm_menu.mpg" pause="inf"/>
        <button name="b1">jump title 1;</button>
        <button name="b2">jump titleset 1 menu;</button>
        <button name="b3">g2 = 7; jump title 2;</button>
      </pgc>
    </menus>
  </vmgm>
  <titleset>
    <menus>
      <video format="ntsc" aspect="4:3"/>
      <pgc entry="root" pause="inf">
        <vob file="$W/vtsm_menu.mpg" pause="inf"/>
        <button name="b1">jump title 1 chapter 1;</button>
        <button name="b2">jump title 1 chapter 2;</button>
        <button name="b3">jump vmgm menu 1;</button>
      </pgc>
    </menus>
    <titles>
      <video format="ntsc" aspect="4:3"/>
      <pgc>
        <vob file="$W/title1.mpg" chapters="0,0:00:01"/>
        <post>call vmgm menu 1;</post>
      </pgc>
      <pgc>
        <vob file="$W/title2.mpg"/>
        <post>if (g2 == 7) call menu; call vmgm menu 1;</post>
      </pgc>
    </titles>
  </titleset>
</dvdauthor>
XML
sed "s#$W/##g" "$W/menu-test.xml" > menu-test.xml   # keep a path-free copy beside the script for readers
dvdauthor -x "$W/menu-test.xml" > "$W/dvdauthor.log" 2>&1 || { cat "$W/dvdauthor.log"; exit 1; }
xorriso -as mkisofs -iso-level 1 -V MENUTEST -o menu-test.iso "$W/DVD" 2>"$W/xorriso.log" || { cat "$W/xorriso.log"; exit 1; }
ls -l menu-test.iso
