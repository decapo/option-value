#!/bin/zsh
# Renders AppIcon.svg into the app's asset catalog. Needs librsvg: brew install librsvg
set -e
cd "${0:A:h}"
out=OptionValue/Assets.xcassets/AppIcon.appiconset
mkdir -p "$out"
echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > OptionValue/Assets.xcassets/Contents.json

images=()
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size AppIcon.svg -o "$out/icon_${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) AppIcon.svg -o "$out/icon_${size}@2x.png"
  images+=("{ \"idiom\" : \"mac\", \"size\" : \"${size}x${size}\", \"scale\" : \"1x\", \"filename\" : \"icon_${size}.png\" }")
  images+=("{ \"idiom\" : \"mac\", \"size\" : \"${size}x${size}\", \"scale\" : \"2x\", \"filename\" : \"icon_${size}@2x.png\" }")
done
echo "{ \"images\" : [ ${(j:, :)images} ], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }" > "$out/Contents.json"
