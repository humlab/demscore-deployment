# The seven quantile colours, in the three orders the legend can read them.
#
# INCLUDEd by every hex fill layer rather than written out per layer: one mesh is
# cut in Equal Earth and one in Web Mercator, and the projection a cell was cut
# in has nothing to do with the colour it takes. class_idx is shifted by the
# DATA query per polarity -- 1-7 negative, 8-x positive, 10+x neutral -- so the
# bar always reads low-to-high left to right.
#
# These seven RGB triples and the LEGEND_COLORS_* lists in
# webapp/src/controllers/MapController.js are the same ramp written twice, in two
# languages. scripts/check_palette_contrast.mjs reads both files and fails if
# they disagree, so run it after touching either -- a legend that paints a
# different ramp from the map is a legend that lies.
#
# The neutral ramp is viridis (trimmed to 0.15-0.85 so neither end reaches
# near-black or the yellow that would collide with the cream no-data land). It
# replaced a seven-step emerald ramp whose two lightest classes were delta-E 6
# apart under protanopia and deuteranopia -- indistinguishable -- and whose
# lightest shade sat delta-E 17 from the no-data colour, so "no value" read as
# "bottom of the scale". Viridis is monotonic in lightness, which is what makes
# the ramp survive greyscale and a projector as well as colour blindness.
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

  CLASS
    NAME "neutral 1"
    EXPRESSION ([class_idx] = 11)
    STYLE
      COLOR 71 45 123
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 2"
    EXPRESSION ([class_idx] = 12)
    STYLE
      COLOR 59 82 139
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 3"
    EXPRESSION ([class_idx] = 13)
    STYLE
      COLOR 44 114 142
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 4"
    EXPRESSION ([class_idx] = 14)
    STYLE
      COLOR 33 145 140
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 5"
    EXPRESSION ([class_idx] = 15)
    STYLE
      COLOR 40 174 128
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 6"
    EXPRESSION ([class_idx] = 16)
    STYLE
      COLOR 94 201 98
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END

  CLASS
    NAME "neutral 7"
    EXPRESSION ([class_idx] = 17)
    STYLE
      COLOR 173 220 48
      OUTLINECOLOR 255 255 255
      WIDTH 0.25
    END
  END
