# GENERATED FILE -- do not edit.
#
# Written by scripts/build_hex_classes.mjs from webapp/src/core/palettes.js,
# which is where the colours live and where they should be changed. Run the
# generator after editing it; scripts/check_palette_contrast.mjs fails if this
# file and the JavaScript have drifted apart.
#
# INCLUDEd by every hex fill layer rather than written out per layer: one mesh
# is cut in Equal Earth and one in Web Mercator, and the projection a cell was
# cut in has nothing to do with the colour it takes.
#
# Each block below is one seven-class band. The DATA query offsets class_idx
# onto a band per colour scheme and polarity, so the class a hexagon lands in
# carries both which scheme was asked for and which way round it reads. A band
# is reversed in SQL (base + (8 - class_idx)) rather than written out twice.

# class_idx 1-7 -- default (signed)
  CLASS
    NAME "1"
    EXPRESSION ([class_idx] = 1)
    STYLE
      COLOR 49 54 149
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "2"
    EXPRESSION ([class_idx] = 2)
    STYLE
      COLOR 69 117 180
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "3"
    EXPRESSION ([class_idx] = 3)
    STYLE
      COLOR 116 173 209
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "4"
    EXPRESSION ([class_idx] = 4)
    STYLE
      COLOR 171 217 233
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "5"
    EXPRESSION ([class_idx] = 5)
    STYLE
      COLOR 253 174 97
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "6"
    EXPRESSION ([class_idx] = 6)
    STYLE
      COLOR 244 109 67
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "7"
    EXPRESSION ([class_idx] = 7)
    STYLE
      COLOR 215 48 39
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

# class_idx 11-17 -- viridis (all variables)
  CLASS
    NAME "11"
    EXPRESSION ([class_idx] = 11)
    STYLE
      COLOR 71 45 123
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "12"
    EXPRESSION ([class_idx] = 12)
    STYLE
      COLOR 59 82 139
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "13"
    EXPRESSION ([class_idx] = 13)
    STYLE
      COLOR 44 114 142
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "14"
    EXPRESSION ([class_idx] = 14)
    STYLE
      COLOR 33 145 140
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "15"
    EXPRESSION ([class_idx] = 15)
    STYLE
      COLOR 40 174 128
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "16"
    EXPRESSION ([class_idx] = 16)
    STYLE
      COLOR 94 201 98
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "17"
    EXPRESSION ([class_idx] = 17)
    STYLE
      COLOR 173 220 48
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

# class_idx 21-27 -- indigo_amber (signed)
  CLASS
    NAME "21"
    EXPRESSION ([class_idx] = 21)
    STYLE
      COLOR 43 42 112
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "22"
    EXPRESSION ([class_idx] = 22)
    STYLE
      COLOR 74 84 168
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "23"
    EXPRESSION ([class_idx] = 23)
    STYLE
      COLOR 139 147 207
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "24"
    EXPRESSION ([class_idx] = 24)
    STYLE
      COLOR 196 189 176
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "25"
    EXPRESSION ([class_idx] = 25)
    STYLE
      COLOR 224 163 60
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "26"
    EXPRESSION ([class_idx] = 26)
    STYLE
      COLOR 178 112 15
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "27"
    EXPRESSION ([class_idx] = 27)
    STYLE
      COLOR 122 71 3
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

# class_idx 31-37 -- cividis (all variables)
  CLASS
    NAME "31"
    EXPRESSION ([class_idx] = 31)
    STYLE
      COLOR 0 45 97
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "32"
    EXPRESSION ([class_idx] = 32)
    STYLE
      COLOR 34 73 110
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "33"
    EXPRESSION ([class_idx] = 33)
    STYLE
      COLOR 74 90 110
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "34"
    EXPRESSION ([class_idx] = 34)
    STYLE
      COLOR 112 112 109
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "35"
    EXPRESSION ([class_idx] = 35)
    STYLE
      COLOR 151 144 107
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "36"
    EXPRESSION ([class_idx] = 36)
    STYLE
      COLOR 193 172 96
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "37"
    EXPRESSION ([class_idx] = 37)
    STYLE
      COLOR 242 223 74
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

# class_idx 41-47 -- default (unsigned)
  CLASS
    NAME "41"
    EXPRESSION ([class_idx] = 41)
    STYLE
      COLOR 0 0 4
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "42"
    EXPRESSION ([class_idx] = 42)
    STYLE
      COLOR 75 17 119
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "43"
    EXPRESSION ([class_idx] = 43)
    STYLE
      COLOR 124 35 134
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "44"
    EXPRESSION ([class_idx] = 44)
    STYLE
      COLOR 183 55 121
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "45"
    EXPRESSION ([class_idx] = 45)
    STYLE
      COLOR 237 121 83
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "46"
    EXPRESSION ([class_idx] = 46)
    STYLE
      COLOR 251 186 114
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "47"
    EXPRESSION ([class_idx] = 47)
    STYLE
      COLOR 252 253 191
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

# class_idx 51-57 -- indigo_amber (unsigned)
  CLASS
    NAME "51"
    EXPRESSION ([class_idx] = 51)
    STYLE
      COLOR 43 42 112
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "52"
    EXPRESSION ([class_idx] = 52)
    STYLE
      COLOR 74 84 168
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "53"
    EXPRESSION ([class_idx] = 53)
    STYLE
      COLOR 120 137 192
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "54"
    EXPRESSION ([class_idx] = 54)
    STYLE
      COLOR 174 182 201
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "55"
    EXPRESSION ([class_idx] = 55)
    STYLE
      COLOR 215 194 145
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "56"
    EXPRESSION ([class_idx] = 56)
    STYLE
      COLOR 237 170 69
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "57"
    EXPRESSION ([class_idx] = 57)
    STYLE
      COLOR 244 223 106
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END
