#!/bin/bash
# Builds the DVD menu test discs used by Tests/AetherEngineTests/DVDMenu. Tools are fixture-only and never
# linked into the engine:  brew install ffmpeg dvdauthor xorriso ; python3 with Pillow (indexed PNGs).
#
# menu-test.iso (menu-test.xml)
#   FP PGC          g1 = 1; jump VMGM title menu
#   VMGM title menu 3 buttons on an infinite still: Play -> title 1, Chapters -> VTSM root,
#                   Extra -> g2 = 7; jump title 2 (GPRM set, then jump)
#   VTSM root menu  chapter 1 / chapter 2 of title 1, back to the VMGM menu
#   Title 1         2 chapters (2 s), post: call VMGM title menu
#   Title 2         1 s, post: g2 == 7 ? call VTSM chapter menu : call VMGM title menu
#
# menu-features.iso (menu-features.xml)
#   FP PGC          jump VMGM title menu
#   VMGM menu 1     16:9 title menu with TWO button groups (widescreen + letterbox subpicture streams):
#                   Chapters -> VTSM chapter menu, Setup -> VTSM audio (setup) menu, Still -> VMGM menu 2
#   VMGM menu 2     still-frame menu: a single-frame cell with a 3 s cell still, one button (back),
#                   post -> VMGM menu 1
#   VTSM chapter    6 buttons -> title 1 chapters 1-6
#   VTSM setup      audio 1 / audio 2 / subtitles on / subtitles off / back (SetSTN commands)
#   Title 1         6 chapters (4 s), two audio streams, one subtitle stream, post: call VMGM title menu
#
# Tests assert structure, not absolute sector numbers (those can shift between tool versions).
set -euo pipefail
cd "$(dirname "$0")"
for t in ffmpeg dvdauthor spumux xorriso python3; do command -v $t >/dev/null || { echo "need $t"; exit 1; }; done
python3 -c 'import PIL' 2>/dev/null || { echo "need Pillow (python3 -m pip install pillow)"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export VIDEO_FORMAT=NTSC

clip() { # name seconds colour aspect [extra ffmpeg args...]
  local name=$1 secs=$2 colour=$3 aspect=$4; shift 4
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=$colour:s=720x480:r=30000/1001:d=$secs" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$secs" -t "$secs" "$@" \
    -target ntsc-dvd -b:v 400k -maxrate 1500k -bufsize 1835k -b:a 64k -ac 2 -aspect "$aspect" \
    -flags +bitexact -fflags +bitexact "$W/$name.mpg"
}

# Indexed PNG (index 0 transparent) with one outlined rectangle per button: spumux maps the indices to
# the subpicture codes and writes real selection / action colours into the PCI. RGBA PNGs come out
# with zero colours, which is why the PNGs are made with Pillow.
buttons_png() { # file r,g,b "x0,y0,x1,y1;..." [fill]
  python3 - "$W/$1" "$2" "$3" "${4:-}" <<'PY'
import sys
from PIL import Image, ImageDraw
path, rgb, boxes, fill = sys.argv[1], [int(v) for v in sys.argv[2].split(',')], sys.argv[3], sys.argv[4]
im = Image.new('P', (720, 480), 0)
im.putpalette([0, 0, 0] + rgb + [0] * 762)
d = ImageDraw.Draw(im)
for b in boxes.split(';'):
    x0, y0, x1, y1 = [int(v) for v in b.split(',')]
    if fill: d.rectangle([x0, y0, x1, y1], fill=1)
    else: d.rectangle([x0, y0, x1, y1], outline=1, width=4)
im.save(path, transparency=0)
PY
}

spu_menu() { # in out stream-id boxes buttons-xml
  buttons_png img.png 255,255,255 "$4"
  buttons_png hl.png 255,255,0 "$4"
  buttons_png sel.png 255,0,0 "$4"
  cat > "$W/spu.xml" <<XML
<subpictures format="NTSC"><stream><spu start="00:00:00.00" force="yes" image="$W/img.png" highlight="$W/hl.png" select="$W/sel.png">
$5
</spu></stream></subpictures>
XML
  spumux -s "$3" -m dvd "$W/spu.xml" < "$W/$1.mpg" > "$W/$2.mpg" 2>>"$W/spumux.log"
}

three="100,100,300,160;100,200,300,260;100,300,300,360"
threeXML='<button name="b1" x0="100" y0="100" x1="300" y1="160" down="b2" up="b3"/>
<button name="b2" x0="100" y0="200" x1="300" y1="260" up="b1" down="b3"/>
<button name="b3" x0="100" y0="300" x1="300" y1="360" up="b2" down="b1"/>'

# ---------------------------------------------------------------- menu-test.iso
clip vmgm_bg 1 navy 4:3
clip vtsm_bg 1 darkgreen 4:3
clip title1 2 gray 4:3
clip title2 1 maroon 4:3
spu_menu vmgm_bg vmgm_menu 0 "$three" "$threeXML"
spu_menu vtsm_bg vtsm_menu 0 "$three" "$threeXML"

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
sed "s#$W/##g" "$W/menu-test.xml" > menu-test.xml
dvdauthor -x "$W/menu-test.xml" > "$W/dvdauthor.log" 2>&1 || { cat "$W/dvdauthor.log"; exit 1; }
xorriso -as mkisofs -iso-level 1 -V MENUTEST -o menu-test.iso "$W/DVD" 2>"$W/xorriso.log" || { cat "$W/xorriso.log"; exit 1; }

# ---------------------------------------------------------------- menu-features.iso
rm -rf "$W/DVD"
clip wide_bg 1 indigo 16:9
clip still_bg 0.04 teal 4:3                    # one frame: a true still-frame menu cell
clip chap_bg 1 darkgreen 4:3
clip setup_bg 1 olive 4:3
# Title 1: 4 s, two audio streams (440 Hz / 880 Hz), then a subtitle stream muxed by spumux below.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=720x480:r=30000/1001:d=4" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=4" -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=4" \
  -map 0:v -map 1:a -map 2:a -t 4 -target ntsc-dvd -b:v 400k -maxrate 1500k -bufsize 1835k -b:a 64k -ac 2 -aspect 4:3 \
  -flags +bitexact -fflags +bitexact "$W/feat_title_nosub.mpg"
buttons_png sub.png 255,255,255 "200,400,520,440" fill
cat > "$W/sub.xml" <<XML
<subpictures format="NTSC"><stream><spu start="00:00:00.50" end="00:00:02.50" image="$W/sub.png"/></stream></subpictures>
XML
spumux -s 0 -m dvd "$W/sub.xml" < "$W/feat_title_nosub.mpg" > "$W/feat_title.mpg" 2>>"$W/spumux.log"

# 16:9 menu: stream 0 = widescreen layout, stream 1 = letterbox layout (buttons squeezed vertically).
spu_menu wide_bg wide_s0 0 "$three" "$threeXML"
lb="100,120,300,165;100,195,300,240;100,270,300,315"
lbXML='<button name="b1" x0="100" y0="120" x1="300" y1="165" down="b2" up="b3"/>
<button name="b2" x0="100" y0="195" x1="300" y1="240" up="b1" down="b3"/>
<button name="b3" x0="100" y0="270" x1="300" y1="315" up="b2" down="b1"/>'
spu_menu wide_s0 wide_menu 1 "$lb" "$lbXML"
spu_menu still_bg still_menu 0 "260,200,460,260" '<button name="b1" x0="260" y0="200" x1="460" y1="260"/>'
six="60,100,300,150;60,200,300,250;60,300,300,350;420,100,660,150;420,200,660,250;420,300,660,350"
sixXML='<button name="b1" x0="60" y0="100" x1="300" y1="150" down="b2" right="b4"/>
<button name="b2" x0="60" y0="200" x1="300" y1="250" up="b1" down="b3" right="b5"/>
<button name="b3" x0="60" y0="300" x1="300" y1="350" up="b2" right="b6"/>
<button name="b4" x0="420" y0="100" x1="660" y1="150" down="b5" left="b1"/>
<button name="b5" x0="420" y0="200" x1="660" y1="250" up="b4" down="b6" left="b2"/>
<button name="b6" x0="420" y0="300" x1="660" y1="350" up="b5" left="b3"/>'
spu_menu chap_bg chap_menu 0 "$six" "$sixXML"
five="100,60,300,110;100,140,300,190;100,220,300,270;100,300,300,350;100,380,300,430"
fiveXML='<button name="b1" x0="100" y0="60" x1="300" y1="110" down="b2"/>
<button name="b2" x0="100" y0="140" x1="300" y1="190" up="b1" down="b3"/>
<button name="b3" x0="100" y0="220" x1="300" y1="270" up="b2" down="b4"/>
<button name="b4" x0="100" y0="300" x1="300" y1="350" up="b3" down="b5"/>
<button name="b5" x0="100" y0="380" x1="300" y1="430" up="b4"/>'
spu_menu setup_bg setup_menu 0 "$five" "$fiveXML"

cat > "$W/menu-features.xml" <<XML
<dvdauthor dest="$W/DVD" jumppad="0">
  <vmgm>
    <fpc>jump vmgm menu 1;</fpc>
    <menus>
      <video format="ntsc" aspect="16:9" widescreen="nopanscan"/>
      <subpicture lang="en"><stream id="0" mode="widescreen"/><stream id="1" mode="letterbox"/></subpicture>
      <pgc entry="title" pause="inf">
        <vob file="$W/wide_menu.mpg" pause="inf"/>
        <button name="b1">jump titleset 1 menu entry ptt;</button>
        <button name="b2">jump titleset 1 menu entry audio;</button>
        <button name="b3">jump vmgm menu 2;</button>
      </pgc>
      <pgc>
        <vob file="$W/still_menu.mpg" pause="3"/>
        <button name="b1">jump vmgm menu 1;</button>
        <post>jump vmgm menu 1;</post>
      </pgc>
    </menus>
  </vmgm>
  <titleset>
    <menus>
      <video format="ntsc" aspect="4:3"/>
      <pgc entry="root ptt" pause="inf">
        <vob file="$W/chap_menu.mpg" pause="inf"/>
        <button name="b1">jump title 1 chapter 1;</button>
        <button name="b2">jump title 1 chapter 2;</button>
        <button name="b3">jump title 1 chapter 3;</button>
        <button name="b4">jump title 1 chapter 4;</button>
        <button name="b5">jump title 1 chapter 5;</button>
        <button name="b6">jump title 1 chapter 6;</button>
      </pgc>
      <pgc entry="audio subtitle" pause="inf">
        <vob file="$W/setup_menu.mpg" pause="inf"/>
        <button name="b1">audio = 0; jump menu entry audio;</button>
        <button name="b2">audio = 1; jump menu entry audio;</button>
        <button name="b3">subtitle = 64; jump menu entry audio;</button>
        <button name="b4">subtitle = 0; jump menu entry audio;</button>
        <button name="b5">jump vmgm menu 1;</button>
      </pgc>
    </menus>
    <titles>
      <video format="ntsc" aspect="4:3"/>
      <audio lang="en"/><audio lang="fr"/>
      <subpicture lang="en"/>
      <pgc>
        <vob file="$W/feat_title.mpg" chapters="0,0:00:00.600,0:00:01.200,0:00:01.800,0:00:02.400,0:00:03.000"/>
        <post>call vmgm menu 1;</post>
      </pgc>
    </titles>
  </titleset>
</dvdauthor>
XML
sed "s#$W/##g" "$W/menu-features.xml" > menu-features.xml
dvdauthor -x "$W/menu-features.xml" > "$W/dvdauthor2.log" 2>&1 || { cat "$W/dvdauthor2.log"; exit 1; }
xorriso -as mkisofs -iso-level 1 -V MENUFEAT -o menu-features.iso "$W/DVD" 2>"$W/xorriso2.log" || { cat "$W/xorriso2.log"; exit 1; }
ls -l menu-test.iso menu-features.iso
